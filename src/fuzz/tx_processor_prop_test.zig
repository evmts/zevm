//! Consensus property and fuzz suite for `tx_processor` state transitions.
//!
//! Part A holds deterministic PRNG property tests (fixed seeds) for:
//!   - exact ETH conservation across London, Shanghai, Cancun, Prague, Osaka
//!   - gas and nonce laws for valid transactions
//!   - full state immutability for rejected transactions
//!   - EIP-7623 calldata floor versus refund-cap ordering
//!   - revert atomicity (SSTORE + ETH transfer + LOG + REVERT)
//!   - Osaka CLZ (0x1e) and P256VERIFY (0x0100) end-to-end execution
//!
//! Part B holds a native `std.testing.fuzz` target that executes arbitrary
//! bytecode and calldata on Prague and Osaka.
//!
//! Every gas expectation in this file is computed by an oracle written here
//! from the EIP text, not by calling back into `tx_processor`, so a regression
//! in the production formulas cannot hide behind a tautology.

const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const tx_processor = @import("../tx_processor.zig");
const host_adapter = @import("../host_adapter.zig");

/// KNOWN BUG (guillotine-mini `src/evm.zig`, top-level `call()` value-reversal
/// blocks at lines ~874-880 and ~899-905): when the top-level frame reverts or
/// halts, the EVM computes `recipient_balance - value` without a snapshot. If
/// the contract already forwarded more wei than it held before the transaction,
/// that u256 subtraction underflows and panics in Debug and ReleaseSafe builds.
///
/// A panic aborts the whole test binary, so until the bug is patched:
///   - the property tests keep reverting contracts from forwarding more than
///     their pre-transaction balance, and
///   - the fuzz target sends zero transaction value.
/// Flip this to `true` after the fix to enable the reproduction test and the
/// unrestricted generators.
const guillotine_top_level_revert_underflow_fixed = false;

const block_gas_limit: u64 = 30_000_000;
const osaka_transaction_gas_cap: u64 = 16_777_216;
const gas_per_blob: u64 = 131_072;
const one_ether: u256 = 1_000_000_000_000_000_000;
const tracked_slot_count = 4;

const london_plus_forks = [_]guillotine_mini.Hardfork{ .LONDON, .SHANGHAI, .CANCUN, .PRAGUE, .OSAKA };

const sender_address = testAddress(0x01);
const peer_address = testAddress(0x02);
const contract_address = testAddress(0x03);
const sink_address = testAddress(0x04);
const helper_contract_address = testAddress(0x05);
const coinbase_address = testAddress(0xCB);

const op_stop: u8 = 0x00;
const op_pop: u8 = 0x50;
const op_sstore: u8 = 0x55;
const op_gas: u8 = 0x5a;
const op_log1: u8 = 0xa1;
const op_call: u8 = 0xf1;
const op_revert: u8 = 0xfd;
const op_invalid: u8 = 0xfe;

/// Test addresses carry a non-zero leading byte so they never collide with a
/// precompile address.
fn testAddress(tag: u8) primitives.Address {
    var bytes = [_]u8{0} ** 20;
    bytes[0] = 0xA5;
    bytes[19] = tag;
    return .{ .bytes = bytes };
}

fn blockContext(base_fee: u256) guillotine_mini.BlockContext {
    return .{
        .chain_id = 1,
        .block_number = 19_426_587,
        .block_timestamp = 1_710_338_135,
        .block_difficulty = 0,
        .block_prevrandao = 0,
        .block_coinbase = coinbase_address,
        .block_gas_limit = block_gas_limit,
        .block_base_fee = base_fee,
        .blob_base_fee = 0,
    };
}

fn legacyTx(params: struct {
    to: ?primitives.Address,
    value: u256,
    data: []const u8,
    gas_limit: u64,
    gas_price: u256,
    nonce: u64,
}) primitives.Transaction.LegacyTransaction {
    return .{
        .nonce = params.nonce,
        .gas_price = params.gas_price,
        .gas_limit = params.gas_limit,
        .to = params.to,
        .value = params.value,
        .data = params.data,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
}

/// Randomized fee market for one transaction. The effective gas price is
/// always `base_fee + tip`; the dynamic-fee variant adds headroom to the cap.
const FeePlan = struct {
    base_fee: u256,
    tip: u256,
    max_fee: u256,
    dynamic: bool,

    fn generate(random: std.Random) FeePlan {
        const base_fee: u256 = if (random.uintLessThan(u8, 5) == 0) 0 else random.uintAtMost(u32, 2_000);
        const tip: u256 = if (random.uintLessThan(u8, 4) == 0) 0 else random.uintAtMost(u32, 500);
        return .{
            .base_fee = base_fee,
            .tip = tip,
            .max_fee = base_fee + tip + random.uintAtMost(u32, 300),
            .dynamic = random.boolean(),
        };
    }

    fn effectivePrice(self: FeePlan) u256 {
        return self.base_fee + self.tip;
    }

    /// Value for the legacy `gas_price` field. Dynamic-fee transactions carry
    /// their fee cap there, matching how block execution feeds `tx_processor`.
    fn txGasPrice(self: FeePlan) u256 {
        return if (self.dynamic) self.max_fee else self.effectivePrice();
    }

    fn options(self: FeePlan, fork: guillotine_mini.Hardfork) tx_processor.ProcessTransactionOptions {
        if (self.dynamic) {
            return .{
                .hardfork_override = fork,
                .receipt_type = .eip1559,
                .max_fee_per_gas = self.max_fee,
                .max_priority_fee_per_gas = self.tip,
            };
        }
        return .{ .hardfork_override = fork };
    }
};

/// Independent intrinsic-gas oracle for message-call transactions (Istanbul+).
fn oracleIntrinsicGas(data: []const u8) u64 {
    var gas: u64 = 21_000;
    for (data) |byte| gas += if (byte == 0) 4 else 16;
    return gas;
}

/// Independent EIP-7623 calldata-floor oracle. Zero before Prague.
fn oracleCalldataFloor(data: []const u8, fork: guillotine_mini.Hardfork) u64 {
    if (!fork.isAtLeast(.PRAGUE)) return 0;
    var tokens: u64 = 0;
    for (data) |byte| tokens += if (byte == 0) 1 else 4;
    return 21_000 + 10 * tokens;
}

/// Smallest gas limit that passes intrinsic and floor validation.
fn oracleMinimumGasLimit(data: []const u8, fork: guillotine_mini.Hardfork) u64 {
    return @max(oracleIntrinsicGas(data), oracleCalldataFloor(data, fork));
}

/// Independent EIP-3529 + EIP-7623 settlement oracle for London and later:
/// cap the refund on the non-floored gas, subtract it, then apply the floor.
fn oracleEffectiveGasUsed(gas_without_floor: u64, floor: u64, refund_counter: u64) u64 {
    const refund = @min(refund_counter, gas_without_floor / 5);
    return @max(gas_without_floor - refund, floor);
}

fn fillCalldata(random: std.Random, buffer: []u8, zero_one_in: u8) void {
    random.bytes(buffer);
    for (buffer) |*byte| {
        if (random.uintLessThan(u8, zero_one_in) == 0) {
            byte.* = 0;
        } else if (byte.* == 0) {
            byte.* = 1;
        }
    }
}

fn totalBalance(sm: *state_manager.StateManager) !u256 {
    var total: u256 = 0;
    var it = sm.accountIterator();
    while (it.next()) |entry| {
        total = try std.math.add(u256, total, entry.value_ptr.balance);
    }
    return total;
}

fn accountCount(sm: *state_manager.StateManager) usize {
    var count: usize = 0;
    var it = sm.accountIterator();
    while (it.next()) |_| count += 1;
    return count;
}

const AccountSnapshot = struct {
    balance: u256,
    nonce: u64,
    code_hash: [32]u8,
    storage: [tracked_slot_count]u256,
};

fn snapshotAccount(sm: *state_manager.StateManager, address: primitives.Address) !AccountSnapshot {
    var snapshot: AccountSnapshot = undefined;
    snapshot.balance = try sm.getBalance(address);
    snapshot.nonce = try sm.getNonce(address);
    std.crypto.hash.sha3.Keccak256.hash(try sm.getCode(address), &snapshot.code_hash, .{});
    for (&snapshot.storage, 0..) |*slot_value, slot| {
        slot_value.* = try sm.getStorage(address, slot);
    }
    return snapshot;
}

const tracked_addresses = [_]primitives.Address{
    sender_address,
    peer_address,
    contract_address,
    sink_address,
    helper_contract_address,
    coinbase_address,
};

const WorldSnapshot = struct {
    accounts: [tracked_addresses.len]AccountSnapshot,
    total_balance: u256,
    account_count: usize,
};

fn snapshotWorld(sm: *state_manager.StateManager) !WorldSnapshot {
    var snapshot: WorldSnapshot = undefined;
    for (tracked_addresses, 0..) |address, i| {
        snapshot.accounts[i] = try snapshotAccount(sm, address);
    }
    snapshot.total_balance = try totalBalance(sm);
    snapshot.account_count = accountCount(sm);
    return snapshot;
}

fn expectWorldUnchanged(sm: *state_manager.StateManager, before: WorldSnapshot) !void {
    const after = try snapshotWorld(sm);
    for (before.accounts, after.accounts) |expected, actual| {
        try std.testing.expectEqual(expected.balance, actual.balance);
        try std.testing.expectEqual(expected.nonce, actual.nonce);
        try std.testing.expectEqualSlices(u8, &expected.code_hash, &actual.code_hash);
        try std.testing.expectEqualSlices(u256, &expected.storage, &actual.storage);
    }
    try std.testing.expectEqual(before.total_balance, after.total_balance);
    try std.testing.expectEqual(before.account_count, after.account_count);
}

/// Minimal EVM assembler over a fixed buffer.
const Assembler = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn op(self: *Assembler, byte: u8) void {
        self.buf[self.len] = byte;
        self.len += 1;
    }

    fn push1(self: *Assembler, value: u8) void {
        self.op(0x60);
        self.op(value);
    }

    fn push32(self: *Assembler, value: u256) void {
        self.op(0x7f);
        std.mem.writeInt(u256, self.buf[self.len..][0..32], value, .big);
        self.len += 32;
    }

    fn push20(self: *Assembler, address: primitives.Address) void {
        self.op(0x73);
        @memcpy(self.buf[self.len..][0..20], &address.bytes);
        self.len += 20;
    }

    /// `SSTORE(slot, value)`.
    fn sstore(self: *Assembler, slot: u8, value: u256) void {
        self.push32(value);
        self.push1(slot);
        self.op(op_sstore);
    }

    /// `CALL(gas(), to, value, 0, 0, 0, 0)` and discard the status word.
    fn callWithValue(self: *Assembler, to: primitives.Address, value: u256) void {
        self.push1(0);
        self.push1(0);
        self.push1(0);
        self.push1(0);
        self.push32(value);
        self.push20(to);
        self.op(op_gas);
        self.op(op_call);
        self.op(op_pop);
    }

    /// `LOG1(0, 0, topic)`.
    fn log1(self: *Assembler, topic: u256) void {
        self.push32(topic);
        self.push1(0);
        self.push1(0);
        self.op(op_log1);
    }

    /// `REVERT(0, 0)`.
    fn revert(self: *Assembler) void {
        self.push1(0);
        self.push1(0);
        self.op(op_revert);
    }

    fn slice(self: *const Assembler) []const u8 {
        return self.buf[0..self.len];
    }
};

// ============================================================================
// Part A.1: conservation of ETH
// ============================================================================

const ConservationScenario = enum {
    transfer,
    self_transfer,
    forward_success,
    forward_revert,
    forward_invalid,
    inner_revert,
};

fn conservationCase(random: std.Random, fork: guillotine_mini.Hardfork, scenario: ConservationScenario) !void {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };

    const fees = FeePlan.generate(random);
    const sender_balance: u256 = one_ether * 1_000 + random.int(u64);
    const sender_nonce = random.uintAtMost(u64, 1_000_000);
    const contract_balance = random.uintAtMost(u64, 1_000_000);
    const sink_balance: u64 = if (random.boolean()) 0 else random.int(u32);
    const peer_balance: u64 = if (random.boolean()) 0 else random.int(u32);
    const helper_balance: u64 = if (random.boolean()) 0 else random.int(u32);
    const coinbase_balance: u64 = if (random.boolean()) 0 else random.int(u32);
    const value = random.uintAtMost(u64, 1_000_000);

    try sm.setBalance(sender_address, sender_balance);
    try sm.setNonce(sender_address, sender_nonce);
    try sm.setBalance(contract_address, contract_balance);
    try sm.setBalance(sink_address, sink_balance);
    try sm.setBalance(peer_address, peer_balance);
    try sm.setBalance(helper_contract_address, helper_balance);
    try sm.setBalance(coinbase_address, coinbase_balance);

    var code = Assembler{};
    var to = contract_address;
    var expect_success = true;
    var forwarded: u64 = 0;
    switch (scenario) {
        .transfer => to = peer_address,
        .self_transfer => to = sender_address,
        .forward_success => {
            forwarded = random.uintAtMost(u64, contract_balance + value);
            code.callWithValue(sink_address, forwarded);
            code.op(op_stop);
        },
        .forward_revert, .forward_invalid => {
            // See `guillotine_top_level_revert_underflow_fixed`.
            const max_forward = if (guillotine_top_level_revert_underflow_fixed) contract_balance + value else contract_balance;
            forwarded = random.uintAtMost(u64, max_forward);
            code.callWithValue(sink_address, forwarded);
            if (scenario == .forward_revert) code.revert() else code.op(op_invalid);
            expect_success = false;
        },
        .inner_revert => {
            forwarded = random.uintAtMost(u64, contract_balance + value);
            code.callWithValue(helper_contract_address, forwarded);
            code.op(op_stop);
            var helper_code = Assembler{};
            helper_code.revert();
            try sm.setCode(helper_contract_address, helper_code.slice());
        },
    }
    if (code.len > 0) try sm.setCode(contract_address, code.slice());

    var data_buffer: [64]u8 = undefined;
    const data = data_buffer[0..random.uintAtMost(usize, data_buffer.len)];
    fillCalldata(random, data, 3);
    const gas_limit = oracleMinimumGasLimit(data, fork) + 120_000 + random.uintAtMost(u64, 40_000);

    const total_before = try totalBalance(&sm);

    const receipt = try tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender_address,
        legacyTx(.{
            .to = to,
            .value = value,
            .data = data,
            .gas_limit = gas_limit,
            .gas_price = fees.txGasPrice(),
            .nonce = sender_nonce,
        }),
        blockContext(fees.base_fee),
        fees.options(fork),
    );
    defer receipt.deinit(std.testing.allocator);

    const gas_used = receipt.gas_used;
    const price = fees.effectivePrice();

    // The conservation law: the only wei that leaves the system is the burned
    // base fee. Not one wei is created or destroyed otherwise.
    const total_after = try totalBalance(&sm);
    try std.testing.expectEqual(total_before, total_after + fees.base_fee * gas_used);

    try std.testing.expectEqual(expect_success, receipt.status.?.success);
    try std.testing.expectEqual(price, receipt.effective_gas_price);
    try std.testing.expect(gas_used <= gas_limit);
    try std.testing.expectEqual(sender_nonce + 1, try sm.getNonce(sender_address));
    try std.testing.expectEqual(@as(u256, coinbase_balance) + fees.tip * gas_used, try sm.getBalance(coinbase_address));

    const sender_after = try sm.getBalance(sender_address);
    switch (scenario) {
        .transfer => {
            try std.testing.expectEqual(sender_balance - value - price * gas_used, sender_after);
            try std.testing.expectEqual(@as(u256, peer_balance) + value, try sm.getBalance(peer_address));
        },
        .self_transfer => {
            try std.testing.expectEqual(sender_balance - price * gas_used, sender_after);
        },
        .forward_success => {
            try std.testing.expectEqual(sender_balance - value - price * gas_used, sender_after);
            try std.testing.expectEqual(@as(u256, sink_balance) + forwarded, try sm.getBalance(sink_address));
            try std.testing.expectEqual(@as(u256, contract_balance) + value - forwarded, try sm.getBalance(contract_address));
        },
        .forward_revert, .forward_invalid => {
            try std.testing.expectEqual(sender_balance - price * gas_used, sender_after);
            try std.testing.expectEqual(@as(u256, sink_balance), try sm.getBalance(sink_address));
            try std.testing.expectEqual(@as(u256, contract_balance), try sm.getBalance(contract_address));
            if (scenario == .forward_invalid) try std.testing.expectEqual(@as(u256, gas_limit), gas_used);
        },
        .inner_revert => {
            try std.testing.expectEqual(sender_balance - value - price * gas_used, sender_after);
            try std.testing.expectEqual(@as(u256, helper_balance), try sm.getBalance(helper_contract_address));
            try std.testing.expectEqual(@as(u256, contract_balance) + value, try sm.getBalance(contract_address));
        },
    }
}

test "property: ETH is conserved exactly across transfers and contract calls on London through Osaka" {
    var prng = std.Random.DefaultPrng.init(0x7a65_766d_c0de_0001);
    const random = prng.random();
    const scenarios = std.enums.values(ConservationScenario);

    // 5 forks x 6 scenarios x 8 rounds = 240 cases; every pair is covered.
    var iteration: usize = 0;
    while (iteration < 240) : (iteration += 1) {
        const fork = london_plus_forks[iteration % london_plus_forks.len];
        const scenario = scenarios[(iteration / london_plus_forks.len) % scenarios.len];
        try conservationCase(random, fork, scenario);
    }
}

test "property: blob fee is burned exactly and blob-count boundaries hold per fork" {
    var prng = std.Random.DefaultPrng.init(0x7a65_766d_c0de_0002);
    const random = prng.random();

    const cases = [_]struct { fork: guillotine_mini.Hardfork, max_blobs: u64 }{
        .{ .fork = .CANCUN, .max_blobs = 6 },
        // Prague has no per-transaction cap below the 9-blob block maximum.
        .{ .fork = .PRAGUE, .max_blobs = 9 },
        // EIP-7594: Osaka caps a transaction at 6 blobs.
        .{ .fork = .OSAKA, .max_blobs = 6 },
    };

    var iteration: usize = 0;
    while (iteration < 150) : (iteration += 1) {
        const case = cases[iteration % cases.len];
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };

        const fees = FeePlan.generate(random);
        const sender_balance: u256 = one_ether * 1_000 + random.int(u64);
        const value = random.uintAtMost(u64, 1_000_000);
        const blob_count = random.intRangeAtMost(u64, 1, case.max_blobs);
        const blob_gas: u256 = blob_count * gas_per_blob;
        const blob_price: u256 = random.uintAtMost(u32, 5_000);
        try sm.setBalance(sender_address, sender_balance);
        try sm.setBalance(peer_address, random.int(u32));

        var blob_hashes: [9][32]u8 = undefined;
        for (blob_hashes[0..blob_count], 0..) |*h, idx| {
            h.* = [_]u8{@intCast(idx)} ** 32;
            h[0] = 0x01;
        }
        const total_before = try totalBalance(&sm);
        const receipt = try tx_processor.processTransactionWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            sender_address,
            legacyTx(.{
                .to = peer_address,
                .value = value,
                .data = &.{},
                .gas_limit = 21_000 + random.uintAtMost(u64, 10_000),
                .gas_price = fees.max_fee,
                .nonce = 0,
            }),
            blockContext(fees.base_fee),
            .{
                .hardfork_override = case.fork,
                .receipt_type = .eip4844,
                .max_fee_per_gas = fees.max_fee,
                .max_priority_fee_per_gas = fees.tip,
                .blob_gas_used = blob_gas,
                .blob_gas_price = blob_price,
                .max_fee_per_blob_gas = blob_price + random.uintAtMost(u32, 100),
                .blob_versioned_hashes = blob_hashes[0..blob_count],
            },
        );
        defer receipt.deinit(std.testing.allocator);

        try std.testing.expect(receipt.status.?.success);
        try std.testing.expectEqual(@as(u256, 21_000), receipt.gas_used);
        try std.testing.expectEqual(@as(?u256, blob_gas), receipt.blob_gas_used);
        try std.testing.expectEqual(@as(?u256, blob_price), receipt.blob_gas_price);

        // Base fee and blob fee are both burned; nothing else leaves.
        const burned = fees.base_fee * receipt.gas_used + blob_price * blob_gas;
        try std.testing.expectEqual(total_before, (try totalBalance(&sm)) + burned);
        try std.testing.expectEqual(
            sender_balance - value - fees.effectivePrice() * receipt.gas_used - blob_price * blob_gas,
            try sm.getBalance(sender_address),
        );
        try std.testing.expectEqual(@as(u64, 1), try sm.getNonce(sender_address));
    }
}

// ============================================================================
// Part A.2: gas and nonce laws for valid transactions
// ============================================================================

const GasLawTarget = enum { eoa, stopper, reverter, invalid, storer, looper };

fn gasLawTargetAddress(target: GasLawTarget) primitives.Address {
    return switch (target) {
        .eoa => peer_address,
        .stopper => testAddress(0x10),
        .reverter => testAddress(0x11),
        .invalid => testAddress(0x12),
        .storer => testAddress(0x13),
        .looper => testAddress(0x14),
    };
}

test "property: valid transactions obey intrinsic <= gas_used <= gas_limit <= block limit and bump the nonce by exactly one" {
    var prng = std.Random.DefaultPrng.init(0x7a65_766d_c0de_0003);
    const random = prng.random();
    const targets = std.enums.values(GasLawTarget);

    for (london_plus_forks) |fork| {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };

        var nonce = random.uintAtMost(u64, 1_000_000);
        try sm.setBalance(sender_address, one_ether * 1_000_000);
        try sm.setNonce(sender_address, nonce);

        try sm.setCode(gasLawTargetAddress(.stopper), &.{op_stop});
        // PUSH1 0, PUSH1 0, REVERT: exactly 6 gas.
        try sm.setCode(gasLawTargetAddress(.reverter), &.{ 0x60, 0x00, 0x60, 0x00, op_revert });
        try sm.setCode(gasLawTargetAddress(.invalid), &.{op_invalid});
        // PUSH1 1, PUSH1 0, SSTORE, STOP.
        try sm.setCode(gasLawTargetAddress(.storer), &.{ 0x60, 0x01, 0x60, 0x00, op_sstore, op_stop });
        // JUMPDEST, PUSH1 0, JUMP: burns all gas.
        try sm.setCode(gasLawTargetAddress(.looper), &.{ 0x5b, 0x60, 0x00, 0x56 });

        // 5 forks x 48 sequential transactions = 240 cases.
        var iteration: usize = 0;
        while (iteration < 48) : (iteration += 1) {
            const target = targets[iteration % targets.len];
            const to = gasLawTargetAddress(target);
            const fees = FeePlan.generate(random);
            const value = random.uintAtMost(u64, 1_000_000);

            var data_buffer: [200]u8 = undefined;
            const data = data_buffer[0..random.uintAtMost(usize, data_buffer.len)];
            fillCalldata(random, data, 2 + random.uintLessThan(u8, 6));

            const intrinsic = oracleIntrinsicGas(data);
            const floor = oracleCalldataFloor(data, fork);
            const minimum = @max(intrinsic, floor);
            const execution_budget = random.uintAtMost(u64, 60_000);
            const gas_limit = minimum + execution_budget;

            // The production intrinsic-gas routine must agree with the oracle.
            try std.testing.expectEqual(intrinsic, tx_processor.intrinsicGasForFork(data, false, fork));

            const sender_before = try sm.getBalance(sender_address);
            const target_before = try sm.getBalance(to);
            const total_before = try totalBalance(&sm);

            const receipt = try tx_processor.processTransactionWithOptions(
                std.testing.allocator,
                &sm,
                adapter.hostInterface(),
                sender_address,
                legacyTx(.{
                    .to = to,
                    .value = value,
                    .data = data,
                    .gas_limit = gas_limit,
                    .gas_price = fees.txGasPrice(),
                    .nonce = nonce,
                }),
                blockContext(fees.base_fee),
                fees.options(fork),
            );
            defer receipt.deinit(std.testing.allocator);

            const gas_used = receipt.gas_used;
            const success = receipt.status.?.success;

            // Gas law.
            try std.testing.expect(gas_used >= intrinsic);
            try std.testing.expect(gas_used >= floor);
            try std.testing.expect(gas_used <= gas_limit);
            try std.testing.expect(gas_limit <= block_gas_limit);
            try std.testing.expectEqual(gas_used, receipt.cumulative_gas_used);
            try std.testing.expectEqual(gas_used, receipt.status.?.gas_used);

            // Nonce law: exactly +1, including on revert and exceptional halt.
            nonce += 1;
            try std.testing.expectEqual(nonce, try sm.getNonce(sender_address));

            // Exact gas for targets whose execution cost is known.
            switch (target) {
                .eoa, .stopper => {
                    try std.testing.expect(success);
                    try std.testing.expectEqual(@as(u256, minimum), gas_used);
                },
                .reverter => {
                    try std.testing.expect(!success);
                    if (gas_limit - intrinsic >= 6) {
                        try std.testing.expectEqual(@as(u256, @max(intrinsic + 6, floor)), gas_used);
                    } else {
                        try std.testing.expectEqual(@as(u256, gas_limit), gas_used);
                    }
                },
                .invalid, .looper => {
                    try std.testing.expect(!success);
                    try std.testing.expectEqual(@as(u256, gas_limit), gas_used);
                },
                .storer => {},
            }

            // Settlement: the sender pays effective_gas_price * gas_used, plus
            // the value only when execution succeeded.
            const fee = fees.effectivePrice() * gas_used;
            const sender_after = try sm.getBalance(sender_address);
            if (success) {
                try std.testing.expectEqual(sender_before - fee - value, sender_after);
                try std.testing.expectEqual(target_before + value, try sm.getBalance(to));
            } else {
                try std.testing.expectEqual(sender_before - fee, sender_after);
                try std.testing.expectEqual(target_before, try sm.getBalance(to));
            }
            try std.testing.expectEqual(total_before, (try totalBalance(&sm)) + fees.base_fee * gas_used);
        }
    }
}

// ============================================================================
// Part A.3: rejected transactions leave all state unchanged
// ============================================================================

const RejectionKind = enum {
    insufficient_balance,
    nonce_too_high,
    nonce_too_low,
    osaka_gas_cap,
    osaka_too_many_blobs,
    block_gas_limit,
    gas_limit_below_minimum,
    gas_price_below_base_fee,
};

fn rejectionCase(random: std.Random, kind: RejectionKind) !void {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };

    var fees = FeePlan.generate(random);
    const sender_balance: u256 = one_ether + random.int(u64);
    const sender_nonce = random.intRangeAtMost(u64, 1, 1_000_000);

    try sm.setBalance(sender_address, sender_balance);
    try sm.setNonce(sender_address, sender_nonce);
    try sm.setBalance(peer_address, random.int(u32));
    try sm.setBalance(coinbase_address, random.int(u32));
    try sm.setBalance(contract_address, random.int(u32));
    // PUSH1 7, PUSH1 0, SSTORE, STOP: would mutate storage if it ever ran.
    try sm.setCode(contract_address, &.{ 0x60, 0x07, 0x60, 0x00, op_sstore, op_stop });
    var slot: u256 = 0;
    while (slot < tracked_slot_count) : (slot += 1) {
        try sm.setStorage(contract_address, slot, random.int(u256) | 1);
    }

    var data_buffer: [96]u8 = undefined;
    const data = data_buffer[0..random.uintAtMost(usize, data_buffer.len)];
    fillCalldata(random, data, 3);

    var fork = london_plus_forks[random.uintLessThan(usize, london_plus_forks.len)];
    const to = if (random.boolean()) contract_address else peer_address;
    var value: u256 = random.uintAtMost(u64, 1_000_000);
    var nonce = sender_nonce;
    var gas_limit: u64 = 0;
    var gas_limit_is_set = false;
    var gas_price_override: ?u256 = null;
    var options_override: ?tx_processor.ProcessTransactionOptions = null;
    var expected: tx_processor.TxError = undefined;

    switch (kind) {
        .insufficient_balance => {
            expected = tx_processor.TxError.InsufficientBalance;
        },
        .nonce_too_high => {
            nonce = sender_nonce + 1 + random.uintAtMost(u64, 1_000);
            expected = tx_processor.TxError.NonceMismatch;
        },
        .nonce_too_low => {
            nonce = random.uintLessThan(u64, sender_nonce);
            expected = tx_processor.TxError.NonceMismatch;
        },
        .osaka_gas_cap => {
            fork = .OSAKA;
            gas_limit = osaka_transaction_gas_cap + 1 + random.uintAtMost(u64, block_gas_limit - osaka_transaction_gas_cap - 1);
            gas_limit_is_set = true;
            expected = tx_processor.TxError.TransactionGasLimitExceeded;
        },
        .osaka_too_many_blobs => {
            fork = .OSAKA;
            const blob_count = random.intRangeAtMost(u64, 7, 64);
            const blob_price: u256 = random.uintAtMost(u32, 5_000);
            options_override = .{
                .hardfork_override = .OSAKA,
                .receipt_type = .eip4844,
                .max_fee_per_gas = fees.max_fee,
                .max_priority_fee_per_gas = fees.tip,
                .blob_gas_used = @as(u256, blob_count) * gas_per_blob,
                .blob_gas_price = blob_price,
                .max_fee_per_blob_gas = blob_price + random.uintAtMost(u32, 100),
            };
            gas_price_override = fees.max_fee;
            expected = tx_processor.TxError.TooManyBlobs;
        },
        .block_gas_limit => {
            // On Osaka the EIP-7825 cap fires first; that is `.osaka_gas_cap`.
            fork = london_plus_forks[random.uintLessThan(usize, london_plus_forks.len - 1)];
            gas_limit = block_gas_limit + 1 + random.uintAtMost(u64, 1_000_000);
            gas_limit_is_set = true;
            expected = tx_processor.TxError.BlockGasLimitExceeded;
        },
        .gas_limit_below_minimum => {
            gas_limit = random.uintLessThan(u64, oracleMinimumGasLimit(data, fork));
            gas_limit_is_set = true;
            expected = tx_processor.TxError.IntrinsicGasExceedsLimit;
        },
        .gas_price_below_base_fee => {
            fees.dynamic = false;
            fees.base_fee = 1 + random.uintAtMost(u32, 2_000);
            gas_price_override = random.uintLessThan(u64, @intCast(fees.base_fee));
            expected = tx_processor.TxError.GasPriceBelowBaseFee;
        },
    }

    if (!gas_limit_is_set) gas_limit = oracleMinimumGasLimit(data, fork) + random.uintAtMost(u64, 100_000);
    const gas_price = gas_price_override orelse fees.txGasPrice();
    if (kind == .insufficient_balance) {
        // value + gas_limit * balance-check price exceeds the balance by >= 1 wei.
        value = sender_balance - gas_price * gas_limit + 1 + random.uintAtMost(u64, 1_000);
    }

    const before = try snapshotWorld(&sm);

    const result = tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender_address,
        legacyTx(.{
            .to = to,
            .value = value,
            .data = data,
            .gas_limit = gas_limit,
            .gas_price = gas_price,
            .nonce = nonce,
        }),
        blockContext(fees.base_fee),
        options_override orelse fees.options(fork),
    );

    if (result) |receipt| {
        // Release an unexpected success so the failure is reported as a
        // missing validation and not as an allocation leak.
        receipt.deinit(std.testing.allocator);
        std.debug.print("rejection kind {s} on {s} was accepted\n", .{ @tagName(kind), @tagName(fork) });
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }

    // Balances, nonces, code, storage, account set: all 100% unchanged.
    try expectWorldUnchanged(&sm, before);
    try std.testing.expectEqual(@as(?host_adapter.HostAdapter.HostError, null), adapter.getHostError());
}

test "property: rejected transactions leave balances, nonces, storage, and code unchanged" {
    var prng = std.Random.DefaultPrng.init(0x7a65_766d_c0de_0004);
    const random = prng.random();
    const kinds = std.enums.values(RejectionKind);

    // 8 rejection kinds x 30 rounds = 240 cases.
    var iteration: usize = 0;
    while (iteration < 240) : (iteration += 1) {
        try rejectionCase(random, kinds[iteration % kinds.len]);
    }
}

test "property: EIP-7825 cap boundary is exact on Osaka and absent on Prague" {
    var prng = std.Random.DefaultPrng.init(0x7a65_766d_c0de_0005);
    const random = prng.random();

    var iteration: usize = 0;
    while (iteration < 150) : (iteration += 1) {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setBalance(sender_address, one_ether * 1_000_000);

        // Sample tightly around the cap, on both sides.
        const delta = random.uintAtMost(u64, 64);
        const above = random.boolean();
        const gas_limit = if (above) osaka_transaction_gas_cap + 1 + delta else osaka_transaction_gas_cap - delta;
        const fork: guillotine_mini.Hardfork = if (random.boolean()) .OSAKA else .PRAGUE;
        const value = random.uintAtMost(u64, 1_000_000);

        const result = tx_processor.processTransactionWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            sender_address,
            legacyTx(.{ .to = peer_address, .value = value, .data = &.{}, .gas_limit = gas_limit, .gas_price = 1, .nonce = 0 }),
            blockContext(0),
            .{ .hardfork_override = fork },
        );

        if (fork == .OSAKA and above) {
            if (result) |receipt| {
                receipt.deinit(std.testing.allocator);
                return error.TestUnexpectedResult;
            } else |err| {
                try std.testing.expectEqual(tx_processor.TxError.TransactionGasLimitExceeded, err);
            }
            try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender_address));
            try std.testing.expectEqual(one_ether * 1_000_000, try sm.getBalance(sender_address));
            try std.testing.expectEqual(@as(u256, 0), try sm.getBalance(peer_address));
        } else {
            const receipt = try result;
            defer receipt.deinit(std.testing.allocator);
            try std.testing.expect(receipt.status.?.success);
            try std.testing.expectEqual(@as(u256, 21_000), receipt.gas_used);
            try std.testing.expectEqual(@as(u64, 1), try sm.getNonce(sender_address));
            try std.testing.expectEqual(@as(u256, value), try sm.getBalance(peer_address));
        }
    }
}

// ============================================================================
// Part A.4: EIP-7623 calldata floor versus refund ordering
// ============================================================================

test "property: effectiveGasUsed caps the refund before applying the calldata floor" {
    var prng = std.Random.DefaultPrng.init(0x7a65_766d_c0de_0006);
    const random = prng.random();

    var discriminating_cases: usize = 0;
    var iteration: usize = 0;
    while (iteration < 3_000) : (iteration += 1) {
        const gas_without_floor = random.intRangeAtMost(u64, 21_000, block_gas_limit);
        const floor: u64 = switch (random.uintLessThan(u8, 3)) {
            0 => 0,
            1 => random.uintAtMost(u64, gas_without_floor),
            else => random.intRangeAtMost(u64, 21_000, block_gas_limit),
        };
        const refund_counter: u64 = switch (random.uintLessThan(u8, 3)) {
            0 => 0,
            1 => random.uintAtMost(u64, gas_without_floor),
            else => random.int(u64),
        };
        const fork = london_plus_forks[random.uintLessThan(usize, london_plus_forks.len)];

        const actual = tx_processor.effectiveGasUsed(gas_without_floor, floor, refund_counter, fork);
        const expected = oracleEffectiveGasUsed(gas_without_floor, floor, refund_counter);
        try std.testing.expectEqual(expected, actual);

        // The floor is a hard lower bound, whatever the refund.
        try std.testing.expect(actual >= floor);
        // The refund never exceeds one fifth of the non-floored gas.
        try std.testing.expect(actual >= gas_without_floor - gas_without_floor / 5);
        try std.testing.expect(actual <= @max(gas_without_floor, floor));
        // When the floor already covers the execution gas, the refund is inert.
        if (floor >= gas_without_floor) try std.testing.expectEqual(floor, actual);
        // A larger refund counter never raises the bill.
        const larger_refund = std.math.add(u64, refund_counter, random.int(u32)) catch std.math.maxInt(u64);
        try std.testing.expect(tx_processor.effectiveGasUsed(gas_without_floor, floor, larger_refund, fork) <= actual);
        // A higher floor never lowers the bill.
        const higher_floor = floor + random.int(u32);
        try std.testing.expect(tx_processor.effectiveGasUsed(gas_without_floor, higher_floor, refund_counter, fork) >= actual);

        // The historical bug floored first and then refunded from the floored value.
        const floored_first = @max(gas_without_floor, floor);
        const wrong_order = floored_first - @min(refund_counter, floored_first / 5);
        if (wrong_order != actual) discriminating_cases += 1;

        // Pre-London forks cap the refund at one half.
        const berlin = tx_processor.effectiveGasUsed(gas_without_floor, 0, refund_counter, .BERLIN);
        try std.testing.expectEqual(gas_without_floor - @min(refund_counter, gas_without_floor / 2), berlin);
    }
    // The generator must reach inputs where the wrong ordering is observable.
    try std.testing.expect(discriminating_cases > 100);
}

test "property: EIP-7623 end-to-end, SSTORE-clear refunds never push gas_used below the calldata floor" {
    var prng = std.Random.DefaultPrng.init(0x7a65_766d_c0de_0007);
    const random = prng.random();

    // Berlin+ cost of `PUSH1 0, PUSH1 slot, SSTORE` clearing a cold, original
    // non-zero slot: 3 + 3 + (2100 cold access + 2900 reset). EIP-3529 refund: 4800.
    const clear_gas: u64 = 5_006;
    const clear_refund: u64 = 4_800;

    var floor_bound_cases: usize = 0;
    var refund_bound_cases: usize = 0;
    var discriminating_cases: usize = 0;

    var data_buffer: [1_600]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 200) : (iteration += 1) {
        const fork: guillotine_mini.Hardfork = if (iteration % 4 < 2) .PRAGUE else .OSAKA;
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };

        const fees = FeePlan.generate(random);
        const sender_balance: u256 = one_ether * 1_000 + random.int(u64);
        try sm.setBalance(sender_address, sender_balance);

        const clears = random.intRangeAtMost(u8, 1, 4);
        var code = Assembler{};
        var slot: u8 = 0;
        while (slot < clears) : (slot += 1) {
            try sm.setStorage(contract_address, slot, random.int(u256) | 1);
            code.sstore(slot, 0);
        }
        code.op(op_stop);
        try sm.setCode(contract_address, code.slice());

        // Even iterations: large, mostly non-zero calldata so the floor binds.
        // Odd iterations: small calldata so the refund cap binds.
        const data = if (iteration % 2 == 0)
            data_buffer[0..random.intRangeAtMost(usize, 1_200, data_buffer.len)]
        else
            data_buffer[0..random.uintAtMost(usize, 64)];
        fillCalldata(random, data, if (iteration % 2 == 0) 16 else 2 + random.uintLessThan(u8, 6));

        const intrinsic = oracleIntrinsicGas(data);
        const floor = oracleCalldataFloor(data, fork);
        const gas_without_floor = intrinsic + clear_gas * clears;
        const refund_counter = clear_refund * clears;
        const expected = oracleEffectiveGasUsed(gas_without_floor, floor, refund_counter);
        const gas_limit = @max(gas_without_floor + random.uintAtMost(u64, 20_000), floor + random.uintAtMost(u64, 1_000));

        const receipt = try tx_processor.processTransactionWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            sender_address,
            legacyTx(.{
                .to = contract_address,
                .value = 0,
                .data = data,
                .gas_limit = gas_limit,
                .gas_price = fees.txGasPrice(),
                .nonce = 0,
            }),
            blockContext(fees.base_fee),
            fees.options(fork),
        );
        defer receipt.deinit(std.testing.allocator);

        try std.testing.expect(receipt.status.?.success);
        slot = 0;
        while (slot < clears) : (slot += 1) {
            try std.testing.expectEqual(@as(u256, 0), try sm.getStorage(contract_address, slot));
        }

        // Law 1: the calldata floor is a hard lower bound.
        try std.testing.expect(receipt.gas_used >= floor);
        // Law 2: the refund is capped on the NON-floored gas.
        try std.testing.expect(receipt.gas_used >= gas_without_floor - gas_without_floor / 5);
        // Law 3: exact agreement with the EIP-3529 + EIP-7623 oracle.
        try std.testing.expectEqual(@as(u256, expected), receipt.gas_used);
        // The sender is billed for exactly the floored, refunded gas.
        try std.testing.expectEqual(
            sender_balance - fees.effectivePrice() * receipt.gas_used,
            try sm.getBalance(sender_address),
        );

        if (expected == floor and floor > gas_without_floor - @min(refund_counter, gas_without_floor / 5)) {
            floor_bound_cases += 1;
        } else {
            refund_bound_cases += 1;
        }
        const floored_first = @max(gas_without_floor, floor);
        if (floored_first - @min(refund_counter, floored_first / 5) != expected) discriminating_cases += 1;
    }

    // Both regimes, and inputs that expose the wrong ordering, must be reached.
    try std.testing.expect(floor_bound_cases > 0);
    try std.testing.expect(refund_bound_cases > 0);
    try std.testing.expect(discriminating_cases > 0);
}

// ============================================================================
// Part A.5: revert atomicity
// ============================================================================

const max_atomic_actions = 6;

const AtomicAction = union(enum) {
    sstore: struct { slot: u8, value: u256 },
    transfer: u64,
    log: u256,
};

const AtomicTerminal = enum { stop, revert, invalid };

const AtomicPlan = struct {
    fork: guillotine_mini.Hardfork,
    fees: FeePlan,
    sender_balance: u256,
    sender_nonce: u64,
    contract_balance: u64,
    sink_balance: u64,
    coinbase_balance: u64,
    value: u64,
    slots: [tracked_slot_count]u256,
    actions: [max_atomic_actions]AtomicAction,
    action_count: usize,
    gas_limit: u64,

    fn generate(random: std.Random, fork: guillotine_mini.Hardfork) AtomicPlan {
        var plan: AtomicPlan = undefined;
        plan.fork = fork;
        plan.fees = FeePlan.generate(random);
        plan.sender_balance = one_ether * 1_000 + random.int(u64);
        plan.sender_nonce = random.uintAtMost(u64, 1_000_000);
        plan.contract_balance = random.uintAtMost(u64, 1_000_000);
        plan.sink_balance = if (random.boolean()) 0 else random.int(u32);
        plan.coinbase_balance = if (random.boolean()) 0 else random.int(u32);
        plan.value = random.uintAtMost(u64, 1_000_000);
        for (&plan.slots) |*slot_value| {
            slot_value.* = if (random.boolean()) 0 else random.int(u256);
        }

        // See `guillotine_top_level_revert_underflow_fixed`: the total
        // forwarded amount stays within the pre-transaction contract balance.
        const forward_budget = if (guillotine_top_level_revert_underflow_fixed)
            plan.contract_balance + plan.value
        else
            plan.contract_balance;
        const per_transfer_cap = forward_budget / max_atomic_actions;

        plan.action_count = random.intRangeAtMost(usize, 3, max_atomic_actions);
        // The first three actions are one SSTORE, one transfer, and one LOG in
        // a random rotation, so every case exercises all three effects.
        const rotation = random.uintLessThan(usize, 3);
        for (0..plan.action_count) |i| {
            const action_kind = if (i < 3) (i + rotation) % 3 else random.uintLessThan(usize, 3);
            plan.actions[i] = switch (action_kind) {
                0 => .{ .sstore = .{
                    .slot = random.uintLessThan(u8, tracked_slot_count),
                    .value = if (random.uintLessThan(u8, 4) == 0) 0 else random.int(u256),
                } },
                1 => .{ .transfer = random.uintAtMost(u64, per_transfer_cap) },
                else => .{ .log = random.int(u256) },
            };
        }
        // Worst case per action is a value CALL to a new account (~36.7k gas).
        plan.gas_limit = 21_000 + 400_000 + random.uintAtMost(u64, 50_000);
        return plan;
    }
};

fn runAtomicPlan(plan: AtomicPlan, terminal: AtomicTerminal) !void {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };

    try sm.setBalance(sender_address, plan.sender_balance);
    try sm.setNonce(sender_address, plan.sender_nonce);
    try sm.setBalance(contract_address, plan.contract_balance);
    try sm.setBalance(sink_address, plan.sink_balance);
    try sm.setBalance(coinbase_address, plan.coinbase_balance);
    for (plan.slots, 0..) |slot_value, slot| {
        try sm.setStorage(contract_address, slot, slot_value);
    }

    // Build the contract and the reference model side by side.
    var code = Assembler{};
    var model_slots = plan.slots;
    var model_forwarded: u256 = 0;
    var model_topics: [max_atomic_actions]u256 = undefined;
    var model_log_count: usize = 0;
    for (plan.actions[0..plan.action_count]) |action| {
        switch (action) {
            .sstore => |write| {
                code.sstore(write.slot, write.value);
                model_slots[write.slot] = write.value;
            },
            .transfer => |amount| {
                code.callWithValue(sink_address, amount);
                model_forwarded += amount;
            },
            .log => |topic| {
                code.log1(topic);
                model_topics[model_log_count] = topic;
                model_log_count += 1;
            },
        }
    }
    switch (terminal) {
        .stop => code.op(op_stop),
        .revert => code.revert(),
        .invalid => code.op(op_invalid),
    }
    try sm.setCode(contract_address, code.slice());

    const total_before = try totalBalance(&sm);
    const code_before = (try snapshotAccount(&sm, contract_address)).code_hash;

    const receipt = try tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender_address,
        legacyTx(.{
            .to = contract_address,
            .value = plan.value,
            .data = &.{},
            .gas_limit = plan.gas_limit,
            .gas_price = plan.fees.txGasPrice(),
            .nonce = plan.sender_nonce,
        }),
        blockContext(plan.fees.base_fee),
        plan.fees.options(plan.fork),
    );
    defer receipt.deinit(std.testing.allocator);

    const gas_used = receipt.gas_used;
    const price = plan.fees.effectivePrice();

    // Common to every outcome: gas is charged, the nonce moves by exactly one,
    // the coinbase earns only the tip, and ETH is conserved.
    try std.testing.expect(gas_used >= 21_000);
    try std.testing.expect(gas_used <= plan.gas_limit);
    try std.testing.expectEqual(plan.sender_nonce + 1, try sm.getNonce(sender_address));
    try std.testing.expectEqual(@as(u256, plan.coinbase_balance) + plan.fees.tip * gas_used, try sm.getBalance(coinbase_address));
    try std.testing.expectEqual(total_before, (try totalBalance(&sm)) + plan.fees.base_fee * gas_used);
    const code_after = (try snapshotAccount(&sm, contract_address)).code_hash;
    try std.testing.expectEqualSlices(u8, &code_before, &code_after);

    if (terminal == .stop) {
        // Control run: the same effects commit when the contract does not revert.
        try std.testing.expect(receipt.status.?.success);
        for (model_slots, 0..) |slot_value, slot| {
            try std.testing.expectEqual(slot_value, try sm.getStorage(contract_address, slot));
        }
        try std.testing.expectEqual(@as(u256, plan.sink_balance) + model_forwarded, try sm.getBalance(sink_address));
        try std.testing.expectEqual(@as(u256, plan.contract_balance) + plan.value - model_forwarded, try sm.getBalance(contract_address));
        try std.testing.expectEqual(plan.sender_balance - plan.value - price * gas_used, try sm.getBalance(sender_address));
        try std.testing.expectEqual(model_log_count, receipt.logs.len);
        for (receipt.logs, 0..) |event_log, i| {
            var topic_bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &topic_bytes, model_topics[i], .big);
            try std.testing.expect(event_log.address.equals(contract_address));
            try std.testing.expectEqual(@as(usize, 1), event_log.topics.len);
            try std.testing.expectEqualSlices(u8, &topic_bytes, &event_log.topics[0]);
        }
        return;
    }

    // Revert atomicity: storage, forwarded ETH, transaction value, and logs
    // are all rolled back.
    try std.testing.expect(!receipt.status.?.success);
    for (plan.slots, 0..) |slot_value, slot| {
        try std.testing.expectEqual(slot_value, try sm.getStorage(contract_address, slot));
    }
    try std.testing.expectEqual(@as(u256, plan.sink_balance), try sm.getBalance(sink_address));
    try std.testing.expectEqual(@as(u256, plan.contract_balance), try sm.getBalance(contract_address));
    try std.testing.expectEqual(@as(usize, 0), receipt.logs.len);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 256), &receipt.logs_bloom);
    // The sender still pays effective_gas_price * gas_used and nothing else.
    try std.testing.expectEqual(plan.sender_balance - price * gas_used, try sm.getBalance(sender_address));

    if (terminal == .invalid) {
        // An exceptional halt consumes the whole gas limit.
        try std.testing.expectEqual(@as(u256, plan.gas_limit), gas_used);
    } else {
        // REVERT returns the unused gas.
        try std.testing.expect(gas_used < plan.gas_limit);
    }
}

test "property: SSTORE + ETH transfer + LOG followed by REVERT restores all state but still charges gas and bumps the nonce" {
    var prng = std.Random.DefaultPrng.init(0x7a65_766d_c0de_0008);
    const random = prng.random();

    // 150 plans, each run three ways (REVERT or INVALID, plus the STOP control).
    var iteration: usize = 0;
    while (iteration < 150) : (iteration += 1) {
        const fork = london_plus_forks[iteration % london_plus_forks.len];
        const plan = AtomicPlan.generate(random, fork);
        try runAtomicPlan(plan, if (iteration % 3 == 2) .invalid else .revert);
        try runAtomicPlan(plan, .stop);
    }
}

test "known bug repro: top-level REVERT after forwarding the transaction value must not underflow (guillotine-mini evm.zig)" {
    // Skipped until guillotine-mini is patched: the unpatched code panics with
    // an integer overflow, which would abort the entire test binary.
    if (!guillotine_top_level_revert_underflow_fixed) return error.SkipZigTest;

    for ([_]AtomicTerminal{ .revert, .invalid }) |terminal| {
        for (london_plus_forks) |fork| {
            var sm = try state_manager.StateManager.init(std.testing.allocator, null);
            defer sm.deinit();
            var adapter = host_adapter.HostAdapter{ .state = &sm };

            // The contract holds 0 wei, receives 100 wei, forwards all 100 wei
            // to the sink, then reverts. Spec: every balance is restored.
            try sm.setBalance(sender_address, one_ether);
            var code = Assembler{};
            code.callWithValue(sink_address, 100);
            if (terminal == .revert) code.revert() else code.op(op_invalid);
            try sm.setCode(contract_address, code.slice());

            const receipt = try tx_processor.processTransactionWithOptions(
                std.testing.allocator,
                &sm,
                adapter.hostInterface(),
                sender_address,
                legacyTx(.{ .to = contract_address, .value = 100, .data = &.{}, .gas_limit = 200_000, .gas_price = 1, .nonce = 0 }),
                blockContext(0),
                .{ .hardfork_override = fork },
            );
            defer receipt.deinit(std.testing.allocator);

            try std.testing.expect(!receipt.status.?.success);
            try std.testing.expectEqual(@as(u256, 0), try sm.getBalance(contract_address));
            try std.testing.expectEqual(@as(u256, 0), try sm.getBalance(sink_address));
            try std.testing.expectEqual(one_ether - receipt.gas_used, try sm.getBalance(sender_address));
            try std.testing.expectEqual(@as(u64, 1), try sm.getNonce(sender_address));
        }
    }
}

// ============================================================================
// Part A.6: Osaka CLZ (0x1e) and P256VERIFY (0x0100)
// ============================================================================

// PUSH1 0, CALLDATALOAD, CLZ, PUSH1 0, MSTORE, PUSH1 0x20, PUSH1 0, RETURN.
const clz_contract_code = [_]u8{ 0x60, 0x00, 0x35, 0x1e, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };

fn clzOperand(random: std.Random, iteration: usize) u256 {
    return switch (iteration) {
        0 => 0,
        1 => std.math.maxInt(u256),
        2 => 1,
        3 => @as(u256, 1) << 255,
        else => switch (iteration % 3) {
            // Exact powers of two: every leading-zero count is reachable.
            0 => @as(u256, 1) << random.int(u8),
            // Uniform bit length.
            1 => random.int(u256) >> random.int(u8),
            else => random.int(u256),
        },
    };
}

test "property: CLZ returns @clz(x) end-to-end on Osaka and is an invalid opcode on Prague" {
    var prng = std.Random.DefaultPrng.init(0x7a65_766d_c0de_0009);
    const random = prng.random();

    // 3 + 3 + 5 (CLZ) + 3 + 3 + 3 (one word of memory) + 3 + 3 + 0.
    const clz_execution_gas: u64 = 26;

    for ([_]guillotine_mini.Hardfork{ .OSAKA, .PRAGUE }) |fork| {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setBalance(sender_address, one_ether * 1_000);
        try sm.setCode(contract_address, &clz_contract_code);

        var nonce: u64 = 0;
        while (nonce < 150) : (nonce += 1) {
            const operand = clzOperand(random, @intCast(nonce));
            var data: [32]u8 = undefined;
            std.mem.writeInt(u256, &data, operand, .big);
            const gas_limit: u64 = 100_000;

            var out: []u8 = &.{};
            defer std.testing.allocator.free(out);
            const receipt = try tx_processor.processTransactionWithOptions(
                std.testing.allocator,
                &sm,
                adapter.hostInterface(),
                sender_address,
                legacyTx(.{ .to = contract_address, .value = 0, .data = &data, .gas_limit = gas_limit, .gas_price = 1, .nonce = nonce }),
                blockContext(0),
                .{ .hardfork_override = fork, .capture_output = &out },
            );
            defer receipt.deinit(std.testing.allocator);

            if (fork == .OSAKA) {
                try std.testing.expect(receipt.status.?.success);
                try std.testing.expectEqual(@as(usize, 32), out.len);
                const result = std.mem.readInt(u256, out[0..32], .big);
                try std.testing.expectEqual(@as(u256, @clz(operand)), result);
                // CLZ is bounded by the word size and hits 256 only for zero.
                try std.testing.expect(result <= 256);
                try std.testing.expectEqual(operand == 0, result == 256);
                const expected_gas = @max(oracleIntrinsicGas(&data) + clz_execution_gas, oracleCalldataFloor(&data, fork));
                try std.testing.expectEqual(@as(u256, expected_gas), receipt.gas_used);
            } else {
                // Prague: 0x1e is undefined, so the frame halts and burns all gas.
                try std.testing.expect(!receipt.status.?.success);
                try std.testing.expectEqual(@as(usize, 0), out.len);
                try std.testing.expectEqual(@as(u256, gas_limit), receipt.gas_used);
            }
            try std.testing.expectEqual(nonce + 1, try sm.getNonce(sender_address));
        }
    }
}

const p256_valid_vector_hex =
    "4cee90eb86eaa050036147a12d49004b6b9c72bd725d39d4785011fe190f0b4d" ++
    "a73bd4903f0ce3b639bbbf6e8e80d16931ff4bcf5993d58468e8fb19086e8cac" ++
    "36dbcd03009df8c59286b162af3bd7fcc0450c9aa81be5d10d312af6c66b1d60" ++
    "4aebd3099c618202fcfe16ae7770b0c49ab5eadf74b754204a3bb6060e44eff3" ++
    "7618b065f9832de4ca6ca971a7a1adc826d0f7c00181a5fb2ddf79ae00b4e10e";

test "property: P256VERIFY at 0x0100 never panics and returns 0 or 32 bytes on Osaka, and is an empty account on Prague" {
    var prng = std.Random.DefaultPrng.init(0x7a65_766d_c0de_000a);
    const random = prng.random();

    var valid_vector: [160]u8 = undefined;
    _ = try std.fmt.hexToBytes(&valid_vector, p256_valid_vector_hex);
    const p256_address = primitives.Address.fromU256(0x0100);
    const p256_gas: u64 = 6_900;

    for ([_]guillotine_mini.Hardfork{ .OSAKA, .PRAGUE }) |fork| {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setBalance(sender_address, one_ether * 1_000);

        var nonce: u64 = 0;
        while (nonce < 150) : (nonce += 1) {
            var input_buffer: [224]u8 = undefined;
            var input: []u8 = input_buffer[0..160];
            var expect_valid = false;
            var expect_invalid = false;

            if (nonce == 0) {
                // The untouched known-answer vector verifies.
                @memcpy(input, &valid_vector);
                expect_valid = true;
            } else switch (nonce % 8) {
                0 => {
                    // One flipped bit in hash, r, or s: full verification, must fail.
                    @memcpy(input, &valid_vector);
                    const bit = random.uintLessThan(usize, 96 * 8);
                    input[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
                    expect_invalid = true;
                },
                1, 2 => {
                    // One flipped bit in the public key: off-curve or wrong key.
                    @memcpy(input, &valid_vector);
                    const bit = 96 * 8 + random.uintLessThan(usize, 64 * 8);
                    input[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
                    expect_invalid = true;
                },
                3 => {
                    // Valid vector with a wrong length (truncated or extended).
                    @memcpy(input_buffer[0..160], &valid_vector);
                    random.bytes(input_buffer[160..]);
                    var length = random.uintAtMost(usize, input_buffer.len);
                    if (length == 160) length = 159;
                    input = input_buffer[0..length];
                    expect_invalid = true;
                },
                4 => {
                    // Boundary scalars: r or s set to zero or to all ones.
                    @memcpy(input, &valid_vector);
                    const offset: usize = if (random.boolean()) 32 else 64;
                    @memset(input[offset..][0..32], if (random.boolean()) 0x00 else 0xff);
                    expect_invalid = true;
                },
                else => {
                    // Arbitrary bytes of arbitrary length.
                    input = input_buffer[0..random.uintAtMost(usize, input_buffer.len)];
                    random.bytes(input);
                },
            }

            const gas_limit: u64 = 100_000;
            var out: []u8 = &.{};
            defer std.testing.allocator.free(out);
            const receipt = try tx_processor.processTransactionWithOptions(
                std.testing.allocator,
                &sm,
                adapter.hostInterface(),
                sender_address,
                legacyTx(.{ .to = p256_address, .value = 0, .data = input, .gas_limit = gas_limit, .gas_price = 1, .nonce = nonce }),
                blockContext(0),
                .{ .hardfork_override = fork, .capture_output = &out },
            );
            defer receipt.deinit(std.testing.allocator);

            const intrinsic = oracleIntrinsicGas(input);
            const floor = oracleCalldataFloor(input, fork);
            try std.testing.expect(receipt.status.?.success);
            try std.testing.expectEqual(nonce + 1, try sm.getNonce(sender_address));

            if (fork == .OSAKA) {
                // Output is empty (invalid) or the 32-byte big-endian word 1.
                try std.testing.expect(out.len == 0 or out.len == 32);
                if (out.len == 32) {
                    try std.testing.expectEqual(@as(u256, 1), std.mem.readInt(u256, out[0..32], .big));
                    // Only a 160-byte input can verify.
                    try std.testing.expectEqual(@as(usize, 160), input.len);
                }
                if (expect_valid) try std.testing.expectEqual(@as(usize, 32), out.len);
                if (expect_invalid) try std.testing.expectEqual(@as(usize, 0), out.len);
                // EIP-7951: a flat 6900 gas whether or not the signature verifies.
                try std.testing.expectEqual(@as(u256, @max(intrinsic + p256_gas, floor)), receipt.gas_used);
            } else {
                // Prague: 0x0100 is a plain empty account.
                try std.testing.expectEqual(@as(usize, 0), out.len);
                try std.testing.expectEqual(@as(u256, @max(intrinsic, floor)), receipt.gas_used);
            }
        }
    }
}

// ============================================================================
// Part B: native coverage-guided fuzz target
// ============================================================================

const fuzz_gas_limit: u64 = 200_000;
const fuzz_max_code_len: usize = 4_096;
const fuzz_sender_balance: u256 = one_ether;
const fuzz_contract_balance: u256 = 1_000_000;
const fuzz_peer_balance: u256 = 5;
const fuzz_coinbase_balance: u256 = 7;

/// Input layout:
///   byte 0      sender nonce
///   byte 1      calldata length (clamped to the remaining input)
///   byte 2      fee market: low 6 bits base fee, high 2 bits priority tip
///   byte 3      transaction value in wei (forced to 0 until the guillotine-mini
///               top-level revert underflow is fixed)
///   bytes 4..   calldata, then contract bytecode
fn fuzzTxProcessor(_: void, input: []const u8) anyerror!void {
    if (input.len < 4) return;
    const body = input[4..];
    const calldata_len = @min(@as(usize, input[1]), body.len);
    const calldata = body[0..calldata_len];
    const code_len = @min(body.len - calldata_len, fuzz_max_code_len);
    const code = body[calldata_len..][0..code_len];

    for ([_]guillotine_mini.Hardfork{ .PRAGUE, .OSAKA }) |fork| {
        try fuzzExecute(fork, input[0], input[2], input[3], calldata, code);
    }
}

fn fuzzExecute(
    fork: guillotine_mini.Hardfork,
    nonce_byte: u8,
    fee_byte: u8,
    value_byte: u8,
    calldata: []const u8,
    code: []const u8,
) !void {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };

    const nonce: u64 = nonce_byte;
    const base_fee: u256 = fee_byte & 0x3f;
    const tip: u256 = fee_byte >> 6;
    const price = base_fee + tip;
    const value: u256 = if (guillotine_top_level_revert_underflow_fixed) value_byte else 0;

    try sm.setBalance(sender_address, fuzz_sender_balance);
    try sm.setNonce(sender_address, nonce);
    try sm.setBalance(contract_address, fuzz_contract_balance);
    try sm.setBalance(peer_address, fuzz_peer_balance);
    try sm.setBalance(coinbase_address, fuzz_coinbase_balance);
    if (code.len > 0) try sm.setCode(contract_address, code);
    var slot: u256 = 0;
    while (slot < tracked_slot_count) : (slot += 1) {
        try sm.setStorage(contract_address, slot, slot + 1);
    }

    const before = try snapshotWorld(&sm);
    const intrinsic = oracleIntrinsicGas(calldata);
    const floor = oracleCalldataFloor(calldata, fork);

    const result = tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender_address,
        legacyTx(.{
            .to = contract_address,
            .value = value,
            .data = calldata,
            .gas_limit = fuzz_gas_limit,
            .gas_price = price,
            .nonce = nonce,
        }),
        blockContext(base_fee),
        .{ .hardfork_override = fork },
    );

    const receipt = result catch |err| {
        // Every generated transaction is valid, so an error is a finding. It
        // must at least have left the state untouched.
        try expectWorldUnchanged(&sm, before);
        return err;
    };
    defer receipt.deinit(std.testing.allocator);

    const gas_used = receipt.gas_used;
    const success = receipt.status.?.success;

    // Gas and nonce laws.
    try std.testing.expect(gas_used >= intrinsic);
    try std.testing.expect(gas_used >= floor);
    try std.testing.expect(gas_used <= fuzz_gas_limit);
    try std.testing.expectEqual(nonce + 1, try sm.getNonce(sender_address));
    try std.testing.expectEqual(price, receipt.effective_gas_price);
    try std.testing.expectEqual(@as(?host_adapter.HostAdapter.HostError, null), adapter.getHostError());

    // ETH conservation. No wei is ever created. Wei is destroyed only by the
    // base-fee burn, except that EIP-6780 lets a contract created in this
    // transaction burn its own balance through SELFDESTRUCT; that needs a
    // CREATE (0xf0) or CREATE2 (0xf5) byte in the code.
    const total_after = try totalBalance(&sm);
    const burned = base_fee * gas_used;
    try std.testing.expect(total_after + burned <= before.total_balance);
    const can_create = std.mem.indexOfAny(u8, code, &.{ 0xf0, 0xf5 }) != null;
    if (!can_create) try std.testing.expectEqual(before.total_balance, total_after + burned);

    if (!success) {
        // Revert atomicity: only the gas payment and the nonce survive.
        try std.testing.expect(receipt.logs.len == 0);
        try std.testing.expectEqual(fuzz_sender_balance - price * gas_used, try sm.getBalance(sender_address));
        try std.testing.expectEqual(fuzz_coinbase_balance + tip * gas_used, try sm.getBalance(coinbase_address));
        try std.testing.expectEqual(fuzz_contract_balance, try sm.getBalance(contract_address));
        try std.testing.expectEqual(fuzz_peer_balance, try sm.getBalance(peer_address));
        try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(contract_address));
        const contract_after = try snapshotAccount(&sm, contract_address);
        // Index 2 of `tracked_addresses` is the contract.
        try std.testing.expectEqualSlices(u8, &before.accounts[2].code_hash, &contract_after.code_hash);
        try std.testing.expectEqualSlices(u256, &before.accounts[2].storage, &contract_after.storage);
    }
}

const fuzz_seed_empty_code = [_]u8{ 0x00, 0x00, 0x00, 0x00 };

// PUSH1 1, PUSH1 0, SSTORE, PUSH1 0, PUSH1 0, LOG0, PUSH1 0, PUSH1 0, REVERT.
const fuzz_seed_sstore_log_revert = [_]u8{ 0x07, 0x00, 0x41, 0x00 } ++
    [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0xa0, 0x60, 0x00, 0x60, 0x00, 0xfd };

// Clears slot 0 (refund) then INVALID, behind 3 bytes of calldata.
const fuzz_seed_clear_then_invalid = [_]u8{ 0xff, 0x03, 0xff, 0x01 } ++
    [_]u8{ 0x00, 0xaa, 0x00 } ++
    [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x55, 0xfe };

// CALL(gas, peer, 1 wei) then STOP.
const fuzz_seed_value_call = [_]u8{ 0x01, 0x00, 0x8a, 0x00 } ++
    [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x01, 0x73 } ++
    peer_address.bytes ++
    [_]u8{ 0x5a, 0xf1, 0x00 };

// CLZ over a 32-byte calldata word: valid on Osaka, invalid on Prague.
const fuzz_seed_clz = [_]u8{ 0x02, 0x20, 0x10, 0x00 } ++
    [_]u8{0x00} ** 16 ++ [_]u8{0x5a} ** 16 ++
    clz_contract_code;

// Copies 160 bytes of calldata to memory and STATICCALLs P256VERIFY at 0x0100.
const fuzz_seed_p256_staticcall = [_]u8{ 0x03, 0xa0, 0x05, 0x00 } ++
    [_]u8{0x11} ** 160 ++
    [_]u8{ 0x36, 0x60, 0x00, 0x60, 0x00, 0x37 } ++
    [_]u8{ 0x60, 0x20, 0x60, 0x00, 0x36, 0x60, 0x00, 0x61, 0x01, 0x00, 0x5a, 0xfa } ++
    [_]u8{ 0x60, 0x20, 0x60, 0x00, 0xf3 };

// JUMPDEST, PUSH1 0, JUMP: runs out of gas.
const fuzz_seed_infinite_loop = [_]u8{ 0x04, 0x00, 0x3f, 0x00 } ++ [_]u8{ 0x5b, 0x60, 0x00, 0x56 };

// SELFDESTRUCT with the peer as beneficiary.
const fuzz_seed_selfdestruct = [_]u8{ 0x05, 0x00, 0xc1, 0x00 } ++
    [_]u8{0x73} ++ peer_address.bytes ++ [_]u8{0xff};

// CREATE with empty init code and zero value, then STOP.
const fuzz_seed_create = [_]u8{ 0x06, 0x00, 0x22, 0x00 } ++
    [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0xf0, 0x00 };

// PUSH32 truncated by the end of the code.
const fuzz_seed_truncated_push = [_]u8{ 0x08, 0x00, 0x01, 0x00 } ++ [_]u8{ 0x7f, 0xff, 0xff };

// MSTORE at offset 2^256 - 1: memory expansion must fail with out-of-gas.
const fuzz_seed_huge_mstore = [_]u8{ 0x09, 0x00, 0x33, 0x00 } ++
    [_]u8{ 0x60, 0x01, 0x7f } ++ [_]u8{0xff} ** 32 ++ [_]u8{0x52};

// TSTORE, TLOAD, SLOAD, BALANCE of self, RETURNDATASIZE, then RETURN(0, 32).
const fuzz_seed_transient_and_reads = [_]u8{ 0x0a, 0x04, 0x7f, 0x00 } ++
    [_]u8{ 0xde, 0xad, 0x00, 0xef } ++
    [_]u8{ 0x60, 0x2a, 0x60, 0x01, 0x5d, 0x60, 0x01, 0x5c, 0x60, 0x00, 0x54, 0x30, 0x31, 0x3d, 0x60, 0x20, 0x60, 0x00, 0xf3 };

test "fuzz: tx_processor executes arbitrary bytecode and calldata on Prague and Osaka" {
    try std.testing.fuzz({}, fuzzTxProcessor, .{
        .corpus = &.{
            &fuzz_seed_empty_code,
            &fuzz_seed_sstore_log_revert,
            &fuzz_seed_clear_then_invalid,
            &fuzz_seed_value_call,
            &fuzz_seed_clz,
            &fuzz_seed_p256_staticcall,
            &fuzz_seed_infinite_loop,
            &fuzz_seed_selfdestruct,
            &fuzz_seed_create,
            &fuzz_seed_truncated_push,
            &fuzz_seed_huge_mstore,
            &fuzz_seed_transient_and_reads,
        },
    });
}
