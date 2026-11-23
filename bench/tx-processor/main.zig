const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const zevm = @import("zevm");
const harness = @import("harness");

fn makeAddress(seed: u64) primitives.Address {
    var addr = primitives.Address.ZERO;
    std.mem.writeInt(u64, addr.bytes[12..20], seed, .big);
    return addr;
}

fn defaultBlockCtx() guillotine_mini.BlockContext {
    return .{
        .chain_id = 1,
        .block_number = 22_000_000,
        .block_timestamp = 1_760_000_000,
        .block_difficulty = 0,
        .block_prevrandao = 0x42,
        .block_coinbase = makeAddress(999),
        .block_gas_limit = 30_000_000,
        .block_base_fee = 1_000_000_000,
        .blob_base_fee = 1,
        .block_hashes = &.{},
    };
}

// Contract: increments storage slot 0, stores slot 1 = slot 0 * 3, emits LOG1, returns 32 bytes.
// PUSH1 0x00, SLOAD, PUSH1 0x01, ADD, DUP1, PUSH1 0x00, SSTORE,
// DUP1, PUSH1 0x03, MUL, PUSH1 0x01, SSTORE,
// PUSH1 0x00, MSTORE, PUSH1 0xaa, PUSH1 0x20, PUSH1 0x00, LOG1,
// PUSH1 0x20, PUSH1 0x00, RETURN
const STORAGE_LOG_BYTECODE = [_]u8{
    0x60, 0x00, 0x54, 0x60, 0x01, 0x01, 0x80, 0x60, 0x00, 0x55,
    0x80, 0x60, 0x03, 0x02, 0x60, 0x01, 0x55,
    0x60, 0x00, 0x52, 0x60, 0xaa, 0x60, 0x20, 0x60, 0x00, 0xa1,
    0x60, 0x20, 0x60, 0x00, 0xf3,
};

// Compute loop contract: 128 iterations of keccak256 over 32 bytes in memory.
// PUSH1 0x80 (counter=128)
// JUMPDEST (pc=2): DUP1, ISZERO, PUSH1 0x1e, JUMPI
//   PUSH1 0x20, PUSH1 0x00, KECCAK256, PUSH1 0x00, MSTORE
//   PUSH1 0x01, SWAP1, SUB
//   PUSH1 0x02, JUMP
// JUMPDEST (pc=0x1e): POP, PUSH1 0x20, PUSH1 0x00, RETURN
const KECCAK_LOOP_BYTECODE = [_]u8{
    0x60, 0x80, // 0..1: PUSH1 128
    0x5b, // 2: JUMPDEST
    0x80, // 3: DUP1
    0x15, // 4: ISZERO
    0x60, 0x16, // 5..6: PUSH1 0x16
    0x57, // 7: JUMPI
    0x60, 0x20, // 8..9: PUSH1 32
    0x60, 0x00, // 10..11: PUSH1 0
    0x20, // 12: KECCAK256
    0x60, 0x00, // 13..14: PUSH1 0
    0x52, // 15: MSTORE
    0x60, 0x01, // 16..17: PUSH1 1
    0x90, // 18: SWAP1
    0x03, // 19: SUB
    0x60, 0x02, // 20..21: PUSH1 2
    0x56, // 22 -> wait let's check offsets: 0x56 is pc=22, so end is pc=23 (0x17)!
};

// Verified exact offsets:
// 0: 60 80  (PUSH1 128)
// 2: 5b     (JUMPDEST)
// 3: 80     (DUP1)
// 4: 15     (ISZERO)
// 5: 60 17  (PUSH1 23)
// 7: 57     (JUMPI)
// 8: 60 20  (PUSH1 32)
// 10: 60 00 (PUSH1 0)
// 12: 20    (KECCAK256)
// 13: 60 00 (PUSH1 0)
// 15: 52    (MSTORE)
// 16: 60 01 (PUSH1 1)
// 18: 90    (SWAP1)
// 19: 03    (SUB)
// 20: 60 02 (PUSH1 2)
// 22: 56    (JUMP)
// 23: 5b    (JUMPDEST)
// 24: 50    (POP)
// 25: 60 20 (PUSH1 32)
// 27: 60 00 (PUSH1 0)
// 29: f3    (RETURN)
const KECCAK_LOOP_CODE = [_]u8{
    0x60, 0x80, 0x5b, 0x80, 0x15, 0x60, 0x17, 0x57,
    0x60, 0x20, 0x60, 0x00, 0x20, 0x60, 0x00, 0x52,
    0x60, 0x01, 0x90, 0x03, 0x60, 0x02, 0x56, 0x5b,
    0x50, 0x60, 0x20, 0x60, 0x00, 0xf3,
};

// Minimal initcode deploying 32 bytes of runtime code
// PUSH32 <32 bytes>, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
const DEPLOY_INITCODE = [_]u8{0x7f} ++ STORAGE_LOG_BYTECODE ++ [_]u8{
    0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "tx-processor");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    const sender = makeAddress(1);
    const receiver = makeAddress(2);
    const storage_contract = makeAddress(10);
    const compute_contract = makeAddress(11);
    const block_ctx = defaultBlockCtx();

    // 1. Intrinsic gas calculation + logs bloom
    {
        const calldata = [_]u8{ 0x00, 0xab, 0xcd, 0xef } ** 256;
        const topics = [_][32]u8{ [_]u8{0xaa} ** 32, [_]u8{0xbb} ** 32 };
        const log_entries = [_]primitives.EventLog.EventLog{
            .{
                .address = storage_contract,
                .topics = &topics,
                .data = calldata[0..64],
                .block_number = 1,
                .transaction_hash = [_]u8{0} ** 32,
                .transaction_index = 0,
                .log_index = 0,
                .removed = false,
            },
        } ** 8;

        const Ctx = struct {
            calldata: []const u8,
            logs: []const primitives.EventLog.EventLog,
            acc: u64 = 0,
        };
        var ctx = Ctx{ .calldata = &calldata, .logs = &log_entries };

        try runner.run("tx_processor/intrinsic_gas_1kb", &ctx, struct {
            fn f(c: *Ctx) !void {
                c.acc +%= zevm.tx_processor.intrinsicGasForFork(c.calldata, false, .PRAGUE);
                std.mem.doNotOptimizeAway(&c.acc);
            }
        }.f, .{ .bytes_per_op = calldata.len });

        try runner.run("tx_processor/compute_logs_bloom_8", &ctx, struct {
            fn f(c: *Ctx) !void {
                const bloom = zevm.tx_processor.computeLogsBloom(c.logs);
                std.mem.doNotOptimizeAway(&bloom);
            }
        }.f, .{});
    }

    // 2. Native ETH transfer execution
    {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        try sm.setBalance(sender, 1_000_000_000_000_000_000_000);
        try sm.setBalance(receiver, 1);
        var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };

        const Ctx = struct {
            allocator: std.mem.Allocator,
            sm: *state_manager.StateManager,
            adapter: *zevm.host_adapter.HostAdapter,
            sender: primitives.Address,
            receiver: primitives.Address,
            block_ctx: guillotine_mini.BlockContext,
            nonce: u64 = 0,
        };
        var ctx = Ctx{
            .allocator = allocator,
            .sm = &sm,
            .adapter = &adapter,
            .sender = sender,
            .receiver = receiver,
            .block_ctx = block_ctx,
        };

        try runner.run("tx_processor/eth_transfer", &ctx, struct {
            fn f(c: *Ctx) !void {
                const tx = primitives.Transaction.LegacyTransaction{
                    .nonce = c.nonce,
                    .gas_price = 2_000_000_000,
                    .gas_limit = 21_000,
                    .to = c.receiver,
                    .value = 1_000,
                    .data = &.{},
                    .v = 27,
                    .r = [_]u8{1} ** 32,
                    .s = [_]u8{1} ** 32,
                };
                var receipt = try zevm.tx_processor.processTransaction(
                    c.allocator,
                    c.sm,
                    c.adapter.hostInterface(),
                    c.sender,
                    tx,
                    c.block_ctx,
                );
                defer receipt.deinit(c.allocator);
                c.nonce += 1;
                std.mem.doNotOptimizeAway(&receipt);
            }
        }.f, .{ .gas_per_op = 21_000 });
    }

    // 3. Storage + Log contract call
    {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        try sm.setBalance(sender, 1_000_000_000_000_000_000_000);
        try sm.setCode(storage_contract, &STORAGE_LOG_BYTECODE);
        try sm.setStorage(storage_contract, 0, 1);
        try sm.setStorage(storage_contract, 1, 3);
        var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };

        const Ctx = struct {
            allocator: std.mem.Allocator,
            sm: *state_manager.StateManager,
            adapter: *zevm.host_adapter.HostAdapter,
            sender: primitives.Address,
            target: primitives.Address,
            block_ctx: guillotine_mini.BlockContext,
            nonce: u64 = 0,
        };
        var ctx = Ctx{
            .allocator = allocator,
            .sm = &sm,
            .adapter = &adapter,
            .sender = sender,
            .target = storage_contract,
            .block_ctx = block_ctx,
        };

        try runner.run("tx_processor/contract_storage_log_call", &ctx, struct {
            fn f(c: *Ctx) !void {
                const tx = primitives.Transaction.LegacyTransaction{
                    .nonce = c.nonce,
                    .gas_price = 2_000_000_000,
                    .gas_limit = 100_000,
                    .to = c.target,
                    .value = 0,
                    .data = &.{},
                    .v = 27,
                    .r = [_]u8{1} ** 32,
                    .s = [_]u8{1} ** 32,
                };
                var receipt = try zevm.tx_processor.processTransaction(
                    c.allocator,
                    c.sm,
                    c.adapter.hostInterface(),
                    c.sender,
                    tx,
                    c.block_ctx,
                );
                defer receipt.deinit(c.allocator);
                c.nonce += 1;
                std.mem.doNotOptimizeAway(&receipt);
            }
        }.f, .{});
    }

    // 4. Compute-heavy EVM keccak loop (128x KECCAK256)
    {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        try sm.setBalance(sender, 1_000_000_000_000_000_000_000);
        try sm.setCode(compute_contract, &KECCAK_LOOP_CODE);
        var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };

        const Ctx = struct {
            allocator: std.mem.Allocator,
            sm: *state_manager.StateManager,
            adapter: *zevm.host_adapter.HostAdapter,
            sender: primitives.Address,
            target: primitives.Address,
            block_ctx: guillotine_mini.BlockContext,
            nonce: u64 = 0,
        };
        var ctx = Ctx{
            .allocator = allocator,
            .sm = &sm,
            .adapter = &adapter,
            .sender = sender,
            .target = compute_contract,
            .block_ctx = block_ctx,
        };

        try runner.run("tx_processor/evm_keccak_loop_128", &ctx, struct {
            fn f(c: *Ctx) !void {
                const tx = primitives.Transaction.LegacyTransaction{
                    .nonce = c.nonce,
                    .gas_price = 2_000_000_000,
                    .gas_limit = 500_000,
                    .to = c.target,
                    .value = 0,
                    .data = &.{},
                    .v = 27,
                    .r = [_]u8{1} ** 32,
                    .s = [_]u8{1} ** 32,
                };
                var receipt = try zevm.tx_processor.processTransaction(
                    c.allocator,
                    c.sm,
                    c.adapter.hostInterface(),
                    c.sender,
                    tx,
                    c.block_ctx,
                );
                defer receipt.deinit(c.allocator);
                c.nonce += 1;
                std.mem.doNotOptimizeAway(&receipt);
            }
        }.f, .{});
    }

    // 5. Contract deployment (CREATE)
    {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        try sm.setBalance(sender, 1_000_000_000_000_000_000_000);
        var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };

        const Ctx = struct {
            allocator: std.mem.Allocator,
            sm: *state_manager.StateManager,
            adapter: *zevm.host_adapter.HostAdapter,
            sender: primitives.Address,
            block_ctx: guillotine_mini.BlockContext,
            nonce: u64 = 0,
        };
        var ctx = Ctx{
            .allocator = allocator,
            .sm = &sm,
            .adapter = &adapter,
            .sender = sender,
            .block_ctx = block_ctx,
        };

        try runner.run("tx_processor/contract_create", &ctx, struct {
            fn f(c: *Ctx) !void {
                const tx = primitives.Transaction.LegacyTransaction{
                    .nonce = c.nonce,
                    .gas_price = 2_000_000_000,
                    .gas_limit = 200_000,
                    .to = null,
                    .value = 0,
                    .data = &DEPLOY_INITCODE,
                    .v = 27,
                    .r = [_]u8{1} ** 32,
                    .s = [_]u8{1} ** 32,
                };
                var receipt = try zevm.tx_processor.processTransaction(
                    c.allocator,
                    c.sm,
                    c.adapter.hostInterface(),
                    c.sender,
                    tx,
                    c.block_ctx,
                );
                defer receipt.deinit(c.allocator);
                c.nonce += 1;
                std.mem.doNotOptimizeAway(&receipt);
            }
        }.f, .{});
    }

    // 6. Precompile execution via tx_processor (SHA256 precompile 0x02)
    {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        try sm.setBalance(sender, 1_000_000_000_000_000_000_000);
        var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };
        const payload = [_]u8{0x5a} ** 1024;

        const Ctx = struct {
            allocator: std.mem.Allocator,
            sm: *state_manager.StateManager,
            adapter: *zevm.host_adapter.HostAdapter,
            sender: primitives.Address,
            block_ctx: guillotine_mini.BlockContext,
            payload: []const u8,
            nonce: u64 = 0,
        };
        var ctx = Ctx{
            .allocator = allocator,
            .sm = &sm,
            .adapter = &adapter,
            .sender = sender,
            .block_ctx = block_ctx,
            .payload = &payload,
        };

        try runner.run("tx_processor/precompile_sha256_1kb", &ctx, struct {
            fn f(c: *Ctx) !void {
                const tx = primitives.Transaction.LegacyTransaction{
                    .nonce = c.nonce,
                    .gas_price = 2_000_000_000,
                    .gas_limit = 100_000,
                    .to = primitives.Address.fromU256(2),
                    .value = 0,
                    .data = c.payload,
                    .v = 27,
                    .r = [_]u8{1} ** 32,
                    .s = [_]u8{1} ** 32,
                };
                var receipt = try zevm.tx_processor.processTransaction(
                    c.allocator,
                    c.sm,
                    c.adapter.hostInterface(),
                    c.sender,
                    tx,
                    c.block_ctx,
                );
                defer receipt.deinit(c.allocator);
                c.nonce += 1;
                std.mem.doNotOptimizeAway(&receipt);
            }
        }.f, .{ .bytes_per_op = payload.len });
    }

    try runner.finish();
}
