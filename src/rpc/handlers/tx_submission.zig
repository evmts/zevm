const std = @import("std");
const primitives = @import("primitives");
const jsonrpc = @import("jsonrpc");
const runtime = @import("../../node/runtime.zig");
const genesis = @import("../../genesis.zig");
const tx_encoding = @import("../../transaction_encoding.zig");
const rpc_parse = @import("../parse.zig");

pub const TxSubmissionError = error{
    InvalidHexData,
    DecodeFailed,
    UnsupportedTxType,
    SenderRecoveryFailed,
    ChainIdMismatch,
    NonceMismatch,
    InsufficientBalance,
    IntrinsicGasExceedsLimit,
    InitcodeTooLarge,
    PoolInsertFailed,
    UnmanagedAccount,
    SigningFailed,
    MiningFailed,
    OutOfMemory,
    StateError,
};

// EIP-3860: 49152 = 2 * MAX_CODE_SIZE
const MAX_INITCODE_SIZE: usize = 49152;

const INTRINSIC_TX: u64 = 21_000;
const INTRINSIC_CREATE: u64 = 32_000;
const CALLDATA_ZERO_GAS: u64 = 4;
const CALLDATA_NONZERO_GAS: u64 = 16;
const INITCODE_WORD_GAS: u64 = 2;

// Phase 1 transaction boundary: only legacy RLP envelopes are accepted on the
// public RPC surface. EIP-2718 typed envelopes (type bytes 0x01..=0x7f, including
// 0x01 EIP-2930, 0x02 EIP-1559, 0x03 EIP-4844, 0x04 EIP-7702) are rejected with
// `UnsupportedTxType`. The dispatcher maps `UnsupportedTxType` to JSON-RPC -32602.
//
// `eth_sendTransaction` similarly rejects request fields that imply typed
// submission (`type`, `accessList`, `maxFeePerGas`, `maxPriorityFeePerGas`,
// `maxFeePerBlobGas`, `blobVersionedHashes`, `blobs`, `commitments`, `proofs`,
// `authorizationList`, `chainId`).
//
// When phase-1 scope changes to admit typed submission, both rejection paths
// must be revisited together with the pool, mining, and signing surfaces.

pub fn handleSendRawTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendRawTransaction.Params,
) TxSubmissionError!jsonrpc.eth.SendRawTransaction.Result {
    const hex_str = switch (params.transaction.value) {
        .string => |s| s,
        else => return TxSubmissionError.InvalidHexData,
    };

    const raw_bytes = primitives.Hex.hexToBytes(allocator, hex_str) catch return TxSubmissionError.InvalidHexData;
    defer allocator.free(raw_bytes);

    if (raw_bytes.len == 0) return TxSubmissionError.InvalidHexData;

    // EIP-2718 type byte range is 0x00..=0x7f; 0xc0..=0xff is RLP list (legacy).
    // Anything in 0x80..=0xbf is RLP string and not a valid top-level tx encoding.
    if (raw_bytes[0] <= 0x7f) return TxSubmissionError.UnsupportedTxType;
    if (raw_bytes[0] < 0xc0) return TxSubmissionError.DecodeFailed;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const decoded = tx_encoding.decodeLegacyEnvelope(raw_bytes) catch return TxSubmissionError.DecodeFailed;

    // Chain id check (legacy may be pre-EIP-155 so chain_id is null).
    if (tx_encoding.legacyChainId(decoded)) |cid| {
        if (cid != rt.chain_id) return TxSubmissionError.ChainIdMismatch;
    }

    const sender = tx_encoding.recoverLegacySender(arena_alloc, decoded) catch return TxSubmissionError.SenderRecoveryFailed;

    const is_create = decoded.to == null;

    // EIP-3860: cap initcode size for create transactions.
    if (is_create and decoded.data.len > MAX_INITCODE_SIZE) {
        return TxSubmissionError.InitcodeTooLarge;
    }

    // Nonce vs state.
    const current_nonce = rt.state.getNonce(sender) catch return TxSubmissionError.StateError;
    if (current_nonce != decoded.nonce) return TxSubmissionError.NonceMismatch;

    // Intrinsic gas.
    const intrinsic = computeLegacyIntrinsicGas(is_create, decoded.data);
    if (intrinsic > decoded.gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;
    if (decoded.gas_limit > rt.dev_runtime.config.block_gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    // Balance covers value + max gas cost.
    const max_gas_cost = decoded.gas_price * @as(u256, decoded.gas_limit);
    const total_cost = decoded.value +| max_gas_cost;
    const balance = rt.state.getBalance(sender) catch return TxSubmissionError.StateError;
    if (balance < total_cost) return TxSubmissionError.InsufficientBalance;

    const tx_hash = computeTxHash(raw_bytes);

    rt.pool.setNonce(sender, current_nonce) catch return TxSubmissionError.PoolInsertFailed;
    rt.pool.add(allocator, .{
        .sender = sender,
        .nonce = decoded.nonce,
        .gas_limit = decoded.gas_limit,
        .max_fee_per_gas = decoded.gas_price,
        .max_priority_fee_per_gas = decoded.gas_price,
        .hash = tx_hash,
        .to = decoded.to,
        .value = decoded.value,
        .input = decoded.data,
        .raw = raw_bytes,
        .v = decoded.v,
        .r = decoded.r,
        .s = decoded.s,
    }) catch |err| switch (err) {
        error.ReplacementUnderpriced => return TxSubmissionError.PoolInsertFailed,
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
    };

    switch (rt.mining_config) {
        .auto => automine(rt) catch return TxSubmissionError.MiningFailed,
        .manual, .interval => {},
    }

    return .{ .value = .{ .bytes = tx_hash } };
}

const SendTransactionRequest = struct {
    from: primitives.Address,
    to: ?primitives.Address = null,
    gas: ?u64 = null,
    gas_price: ?u256 = null,
    value: u256 = 0,
    nonce: ?u64 = null,
    data: []const u8 = &.{},
    owns_data: bool = false,

    fn deinit(self: SendTransactionRequest, allocator: std.mem.Allocator) void {
        if (self.owns_data) allocator.free(self.data);
    }
};

const SendTransactionParseError = error{
    InvalidTransactionRequest,
    InvalidAddress,
    UnsupportedTxType,
    OutOfMemory,
};

fn parseQuantityU64Value(value: std.json.Value) SendTransactionParseError!u64 {
    return rpc_parse.parseQuantityValue(u64, value) catch error.InvalidTransactionRequest;
}

fn managedDevPrivateKey(address: primitives.Address) ?[32]u8 {
    for (genesis.DEV_ACCOUNTS) |account| {
        if (std.mem.eql(u8, &account.address.bytes, &address.bytes)) return account.private_key;
    }
    return null;
}

pub fn handleSendTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendTransaction.Params,
) TxSubmissionError!jsonrpc.eth.SendTransaction.Result {
    const request = parseSendTransactionRequest(allocator, params) catch |err| switch (err) {
        error.UnsupportedTxType => return TxSubmissionError.UnsupportedTxType,
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
        error.InvalidAddress, error.InvalidTransactionRequest => return TxSubmissionError.InvalidHexData,
    };
    defer request.deinit(allocator);
    if (!rt.canSignForAccount(request.from)) return TxSubmissionError.UnmanagedAccount;

    const current_nonce = rt.state.getNonce(request.from) catch return TxSubmissionError.StateError;
    const nonce = request.nonce orelse current_nonce;
    if (current_nonce != nonce) return TxSubmissionError.NonceMismatch;

    const gas_price = request.gas_price orelse rt.gas_price;
    var tx = primitives.Transaction.LegacyTransaction{
        .nonce = nonce,
        .gas_price = gas_price,
        .gas_limit = request.gas orelse 0,
        .to = request.to,
        .value = request.value,
        .data = request.data,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    const intrinsic = computeLegacyIntrinsicGas(tx.to == null, tx.data);
    tx.gas_limit = request.gas orelse intrinsic;
    if (intrinsic > tx.gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;
    if (tx.gas_limit > rt.dev_runtime.config.block_gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    const max_gas_cost = gas_price * @as(u256, tx.gas_limit);
    const total_cost = tx.value +| max_gas_cost;
    const balance = rt.state.getBalance(request.from) catch return TxSubmissionError.StateError;
    if (balance < total_cost) return TxSubmissionError.InsufficientBalance;

    if (managedDevPrivateKey(request.from)) |private_key| {
        tx = tx_encoding.signLegacyTransaction(allocator, tx, private_key, rt.chain_id) catch return TxSubmissionError.SigningFailed;
    }

    const raw = tx_encoding.encodeLegacyTransactionEnvelope(allocator, tx) catch return TxSubmissionError.SigningFailed;
    defer allocator.free(raw);
    const tx_hash = computeTxHash(raw);

    rt.pool.setNonce(request.from, current_nonce) catch return TxSubmissionError.PoolInsertFailed;
    rt.pool.add(allocator, .{
        .sender = request.from,
        .nonce = tx.nonce,
        .gas_limit = tx.gas_limit,
        .max_fee_per_gas = tx.gas_price,
        .max_priority_fee_per_gas = 0,
        .hash = tx_hash,
        .to = tx.to,
        .value = tx.value,
        .input = tx.data,
        .raw = raw,
        .v = tx.v,
        .r = tx.r,
        .s = tx.s,
    }) catch |err| switch (err) {
        error.ReplacementUnderpriced => return TxSubmissionError.PoolInsertFailed,
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
    };

    switch (rt.mining_config) {
        .auto => automine(rt) catch return TxSubmissionError.MiningFailed,
        .manual, .interval => {},
    }

    return .{ .value = .{ .bytes = tx_hash } };
}

// Phase-1-only: keys that imply a typed/dynamic-fee/blob/auth submission. Listed
// explicitly so the rejection is visible to reviewers and stays aligned with
// the documented contract.
fn isTypedSubmissionKey(key: []const u8) bool {
    const typed_keys = [_][]const u8{
        "type",
        "accessList",
        "maxFeePerGas",
        "maxPriorityFeePerGas",
        "maxFeePerBlobGas",
        "blobVersionedHashes",
        "blobs",
        "commitments",
        "proofs",
        "authorizationList",
        "chainId",
    };
    inline for (typed_keys) |typed_key| {
        if (std.mem.eql(u8, key, typed_key)) return true;
    }
    return false;
}

fn parseSendTransactionRequest(
    allocator: std.mem.Allocator,
    params: jsonrpc.eth.SendTransaction.Params,
) SendTransactionParseError!SendTransactionRequest {
    const tx_object = switch (params.transaction.value) {
        .object => |object| object,
        else => return error.InvalidTransactionRequest,
    };

    var request = SendTransactionRequest{ .from = undefined };
    var saw_from = false;
    var data_value: ?[]const u8 = null;
    var input_value: ?[]const u8 = null;
    errdefer {
        if (data_value) |data| allocator.free(data);
        if (input_value) |input| allocator.free(input);
    }

    var it = tx_object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "from")) {
            request.from = try parseAddressValue(value);
            saw_from = true;
        } else if (std.mem.eql(u8, key, "to")) {
            request.to = if (value == .null) null else try parseAddressValue(value);
        } else if (std.mem.eql(u8, key, "gas")) {
            request.gas = try parseQuantityU64Value(value);
        } else if (std.mem.eql(u8, key, "gasPrice")) {
            request.gas_price = try parseQuantityU256Value(value);
        } else if (std.mem.eql(u8, key, "value")) {
            request.value = try parseQuantityU256Value(value);
        } else if (std.mem.eql(u8, key, "nonce")) {
            request.nonce = try parseQuantityU64Value(value);
        } else if (std.mem.eql(u8, key, "data")) {
            data_value = try parseHexDataValue(allocator, value);
        } else if (std.mem.eql(u8, key, "input")) {
            input_value = try parseHexDataValue(allocator, value);
        } else if (isTypedSubmissionKey(key)) {
            return error.UnsupportedTxType;
        } else {
            return error.InvalidTransactionRequest;
        }
    }

    if (!saw_from) return error.InvalidTransactionRequest;
    if (data_value != null and input_value != null and !std.mem.eql(u8, data_value.?, input_value.?)) {
        return error.InvalidTransactionRequest;
    }

    if (data_value) |data| {
        request.data = data;
        request.owns_data = true;
        if (input_value) |input| {
            allocator.free(input);
            input_value = null;
        }
        data_value = null;
    } else if (input_value) |input| {
        request.data = input;
        request.owns_data = true;
        input_value = null;
    }

    return request;
}

fn parseAddressValue(value: std.json.Value) SendTransactionParseError!primitives.Address {
    return rpc_parse.parseAddressValue(value) catch error.InvalidAddress;
}

fn parseAddressString(text: []const u8) SendTransactionParseError!primitives.Address {
    return rpc_parse.parseAddressString(text) catch error.InvalidAddress;
}

fn parseQuantityU256Value(value: std.json.Value) SendTransactionParseError!u256 {
    return rpc_parse.parseQuantityValue(u256, value) catch error.InvalidTransactionRequest;
}

fn parseQuantityString(comptime T: type, text: []const u8) SendTransactionParseError!T {
    return rpc_parse.parseQuantityString(T, text) catch error.InvalidTransactionRequest;
}

fn isQuantityHex(text: []const u8) bool {
    return rpc_parse.isQuantityHex(text);
}

fn parseHexDataValue(allocator: std.mem.Allocator, value: std.json.Value) SendTransactionParseError![]const u8 {
    return rpc_parse.parseHexDataBytes(allocator, value) catch error.InvalidTransactionRequest;
}

// --- Intrinsic gas (legacy only; EIP-2028 calldata) ---------------------

fn computeLegacyIntrinsicGas(is_create: bool, data: []const u8) u64 {
    var gas: u64 = INTRINSIC_TX;
    if (is_create) gas += INTRINSIC_CREATE;

    for (data) |b| {
        gas += if (b == 0) CALLDATA_ZERO_GAS else CALLDATA_NONZERO_GAS;
    }

    if (is_create) {
        const word_count = (data.len + 31) / 32;
        gas += INITCODE_WORD_GAS * @as(u64, @intCast(word_count));
    }

    return gas;
}

fn keccak(input: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(input, &out, .{});
    return out;
}

// --- Hash + automine -----------------------------------------------------

fn computeTxHash(raw_bytes: []const u8) [32]u8 {
    return keccak(raw_bytes);
}

fn automine(rt: *runtime.NodeRuntime) !void {
    try rt.mineBlocks(1, 0);
}
