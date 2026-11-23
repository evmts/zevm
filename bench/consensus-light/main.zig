const std = @import("std");
const primitives = @import("primitives");
const zevm = @import("zevm");
const harness = @import("harness");

fn buildFinalityUpdateJson(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    const beacon_root = zevm.beacon_api.bytesToHex(32, [_]u8{0x01} ** 32);
    const execution_hash = zevm.beacon_api.bytesToHex(32, [_]u8{0x04} ** 32);
    const fee_recipient = zevm.beacon_api.bytesToHex(20, [_]u8{0x05} ** 20);
    const logs_bloom = zevm.beacon_api.bytesToHex(256, [_]u8{0x08} ** 256);
    const branch_el = zevm.beacon_api.bytesToHex(32, [_]u8{0x0d} ** 32);
    const bits_hex = zevm.beacon_api.bytesToHex(64, [_]u8{0xaa} ** 64);
    const sig_hex = zevm.beacon_api.bytesToHex(96, [_]u8{0xbb} ** 96);

    try w.writeAll("{\"version\":\"electra\",\"data\":{\"attested_header\":");
    inline for (0..2) |h| {
        if (h == 1) try w.writeAll(",\"finalized_header\":");
        try w.print(
            "{{\"beacon\":{{\"slot\":\"8000000\",\"proposer_index\":\"123\",\"parent_root\":\"{s}\",\"state_root\":\"{s}\",\"body_root\":\"{s}\"}},\"execution\":{{\"parent_hash\":\"{s}\",\"fee_recipient\":\"{s}\",\"state_root\":\"{s}\",\"receipts_root\":\"{s}\",\"logs_bloom\":\"{s}\",\"prev_randao\":\"{s}\",\"block_number\":\"9000000\",\"gas_limit\":\"30000000\",\"gas_used\":\"12000000\",\"timestamp\":\"1700000000\",\"base_fee_per_gas\":\"1000000000\",\"block_hash\":\"{s}\",\"transactions_root\":\"{s}\",\"withdrawals_root\":\"{s}\",\"blob_gas_used\":\"0\",\"excess_blob_gas\":\"0\"}},\"execution_branch\":[\"{s}\",\"{s}\",\"{s}\",\"{s}\"]}}",
            .{
                beacon_root, beacon_root, beacon_root,
                execution_hash, fee_recipient, execution_hash, execution_hash,
                logs_bloom, execution_hash, execution_hash, execution_hash,
                execution_hash, branch_el, branch_el, branch_el, branch_el,
            },
        );
    }
    try w.writeAll(",\"finality_branch\":[");
    for (0..7) |i| {
        if (i != 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{branch_el});
    }
    try w.print(
        "],\"sync_aggregate\":{{\"sync_committee_bits\":\"{s}\",\"sync_committee_signature\":\"{s}\"}},\"signature_slot\":\"8000001\"}}}}",
        .{ bits_hex, sig_hex },
    );
    return try out.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "consensus-light");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    // 1. Beacon API hex/integer parsing & finality update JSON parsing
    {
        const finality_json = try buildFinalityUpdateJson(allocator);
        defer allocator.free(finality_json);
        const hex32 = zevm.beacon_api.bytesToHex(32, [_]u8{0x5c} ** 32);

        const Ctx = struct {
            allocator: std.mem.Allocator,
            finality_json: []const u8,
            hex32: []const u8,
        };
        var ctx = Ctx{
            .allocator = allocator,
            .finality_json = finality_json,
            .hex32 = &hex32,
        };

        try runner.run("beacon_api/hex_to_bytes_32", &ctx, struct {
            fn f(c: *Ctx) !void {
                const out = try zevm.beacon_api.hexToBytes(32, c.hex32);
                std.mem.doNotOptimizeAway(&out);
            }
        }.f, .{ .bytes_per_op = 32 });

        try runner.run("beacon_api/parse_finality_update_json", &ctx, struct {
            fn f(c: *Ctx) !void {
                const upd = try zevm.beacon_api.parseFinalityUpdateResponse(c.allocator, c.finality_json);
                std.mem.doNotOptimizeAway(&upd);
            }
        }.f, .{ .bytes_per_op = finality_json.len });
    }

    // 2. Consensus verifier: beaconHeaderRoot, computeDomain, computeSigningRoot, getParticipatingKeys
    {
        const header = primitives.LightClientHeader.LightClientHeader.BeaconBlockHeader{
            .slot = 8_500_000,
            .proposer_index = 42_123,
            .parent_root = [_]u8{0x11} ** 32,
            .state_root = [_]u8{0x22} ** 32,
            .body_root = [_]u8{0x33} ** 32,
        };
        const fork_version = [_]u8{ 0x05, 0x00, 0x00, 0x00 };
        const genesis_validators_root = [_]u8{0x4b} ** 32;
        const fork_data_root = try zevm.consensus_verifier.computeForkDataRoot(fork_version, genesis_validators_root);

        var committee: primitives.SyncCommittee.SyncCommittee = undefined;
        for (0..primitives.SyncCommittee.SYNC_COMMITTEE_SIZE) |i| {
            @memset(&committee.pubkeys[i], @intCast(i & 0xff));
        }
        @memset(&committee.aggregate_pubkey, 0xaa);
        const bits = [_]u8{0xef} ** 64; // ~448 of 512 bits set

        const Ctx = struct {
            allocator: std.mem.Allocator,
            header: primitives.LightClientHeader.LightClientHeader.BeaconBlockHeader,
            fork_data_root: [32]u8,
            committee: primitives.SyncCommittee.SyncCommittee,
            bits: [64]u8,
        };
        var ctx = Ctx{
            .allocator = allocator,
            .header = header,
            .fork_data_root = fork_data_root,
            .committee = committee,
            .bits = bits,
        };

        try runner.run("consensus_verifier/beacon_header_root", &ctx, struct {
            fn f(c: *Ctx) !void {
                const r = zevm.consensus_verifier.beaconHeaderRoot(c.header);
                std.mem.doNotOptimizeAway(&r);
            }
        }.f, .{});

        try runner.run("consensus_verifier/compute_committee_sign_root", &ctx, struct {
            fn f(c: *Ctx) !void {
                const hr = zevm.consensus_verifier.beaconHeaderRoot(c.header);
                const sr = zevm.consensus_verifier.computeCommitteeSignRoot(hr, c.fork_data_root);
                std.mem.doNotOptimizeAway(&sr);
            }
        }.f, .{});

        try runner.run("consensus_verifier/get_participating_keys_512", &ctx, struct {
            fn f(c: *Ctx) !void {
                const keys = zevm.consensus_verifier.getParticipatingKeys(c.committee.pubkeys, c.bits);
                std.mem.doNotOptimizeAway(&keys.len);
            }
        }.f, .{});
    }

    // 3. Checkpoint save + load roundtrip (temp dir under .zig-cache)
    {
        const dir_path = ".zig-cache/bench-tmp/checkpoint";
        try std.fs.cwd().makePath(dir_path);

        const Ctx = struct {
            allocator: std.mem.Allocator,
            dir: []const u8,
            hash: [32]u8 = [_]u8{0x7e} ** 32,
        };
        var ctx = Ctx{ .allocator = allocator, .dir = dir_path };

        try runner.run("checkpoint/save_and_load_roundtrip", &ctx, struct {
            fn f(c: *Ctx) !void {
                try zevm.checkpoint.saveCheckpoint(c.allocator, c.dir, c.hash);
                const loaded = try zevm.checkpoint.loadCheckpoint(c.allocator, c.dir);
                std.mem.doNotOptimizeAway(&loaded);
            }
        }.f, .{});
    }

    try runner.finish();
}
