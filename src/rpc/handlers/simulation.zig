const std = @import("std");
const primitives = @import("primitives");
const guillotine_mini = @import("guillotine_mini");
const precompiles = @import("precompiles");
const runtime = @import("../../node/runtime.zig");
const block_builder = @import("../../block_builder.zig");
const host_adapter = @import("../../host_adapter.zig");
const tx_encoding = @import("../../transaction_encoding.zig");
const tx_processor = @import("../../tx_processor.zig");
const precompile_compat = @import("../../precompile_compat.zig");
const rpc_parse = @import("../parse.zig");

pub const MODE_UNSUPPORTED_ERROR_CODE: i32 = -32010;
pub const MODE_UNSUPPORTED_MESSAGE = "mode-unsupported";
const MAX_RPC_ERROR_DATA_HEX_BYTES: usize = 32 * 1024;
const MAX_SIMULATION_RPC_ERROR_MESSAGE_BYTES: usize = 1024;
const SIMULATE_DEFAULT_GAS_CAP: u64 = 50_000_000;
const SIMULATE_MAX_BLOCK_STATE_CALLS: usize = 256;
const SIMULATE_BLOCK_TIME_INCREMENT: u64 = 12;

threadlocal var last_execution_error_data_buf: [MAX_RPC_ERROR_DATA_HEX_BYTES]u8 = undefined;
threadlocal var last_execution_error_data: ?[]const u8 = null;
threadlocal var last_simulation_rpc_error_message_buf: [MAX_SIMULATION_RPC_ERROR_MESSAGE_BYTES]u8 = undefined;
threadlocal var last_simulation_rpc_error: ?SimulationRpcError = null;

pub const SimulationRpcError = struct {
    code: i32,
    message: []const u8,
};

const TransactionRequest = struct {
    from: ?primitives.Address = null,
    to: ?primitives.Address = null,
    gas: ?u64 = null,
    gas_price: ?u256 = null,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
    max_fee_per_blob_gas: ?u256 = null,
    has_fee_fields: bool = false,
    value: u256 = 0,
    nonce: ?u64 = null,
    chain_id: ?u64 = null,
    tx_type: ?u8 = null,
    access_list_addresses: u64 = 0,
    access_list_storage_keys: u64 = 0,
    access_list: []primitives.Transaction.AccessListItem = &.{},
    processor_access_list: []primitives.AccessList.AccessListEntry = &.{},
    blob_versioned_hashes: [][32]u8 = &.{},
    data: []u8,

    fn deinit(self: *TransactionRequest, allocator: std.mem.Allocator) void {
        for (self.access_list) |entry| allocator.free(entry.storage_keys);
        if (self.access_list.len != 0) allocator.free(self.access_list);
        if (self.processor_access_list.len != 0) allocator.free(self.processor_access_list);
        if (self.blob_versioned_hashes.len != 0) allocator.free(self.blob_versioned_hashes);
        allocator.free(self.data);
    }
};

const ParsedCallParams = struct {
    tx: TransactionRequest,
    block: std.json.Value,
    state_overrides: ?std.json.Value = null,

    fn deinit(self: *ParsedCallParams, allocator: std.mem.Allocator) void {
        self.tx.deinit(allocator);
    }
};

const ParsedEstimateParams = struct {
    tx: TransactionRequest,
    block: ?std.json.Value = null,
    state_overrides: ?std.json.Value = null,

    fn deinit(self: *ParsedEstimateParams, allocator: std.mem.Allocator) void {
        self.tx.deinit(allocator);
    }
};

const ParsedCreateAccessListParams = struct {
    tx: TransactionRequest,
    block: ?std.json.Value = null,

    fn deinit(self: *ParsedCreateAccessListParams, allocator: std.mem.Allocator) void {
        self.tx.deinit(allocator);
    }
};

const ExecutionResult = struct {
    output: []u8,
    gas_used: u64,

    fn deinit(self: *ExecutionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

const ExecuteOptions = struct {
    persist_state: bool = false,
    increment_nonce: bool = false,
};

const SimulateOptions = struct {
    trace_transfers: bool = false,
    validation: bool = false,
    return_full_transactions: bool = false,
};

const SimulatedNonceState = struct {
    address: primitives.Address,
    next_nonce: u64,
};

const PrecompileMove = struct {
    source: primitives.Address,
    target: primitives.Address,
};

const PrecompileMoveState = struct {
    moves: std.ArrayList(PrecompileMove) = .{},

    fn deinit(self: *PrecompileMoveState, allocator: std.mem.Allocator) void {
        self.moves.deinit(allocator);
    }

    fn apply(
        self: *PrecompileMoveState,
        allocator: std.mem.Allocator,
        source: primitives.Address,
        target: primitives.Address,
        fork: guillotine_mini.Hardfork,
    ) !void {
        if (!precompiles.isPrecompile(source, fork)) {
            const address_text = try checksumAddressString(allocator, source);
            defer allocator.free(address_text);
            setSimulationRpcErrorFmt(-32000, "account {s} is not a precompile", .{address_text});
            return error.SimulationRpcError;
        }
        if (source.equals(target)) {
            setSimulationRpcErrorStatic(-38022, "movePrecompileToAddress cannot reference itself");
            return error.SimulationRpcError;
        }

        for (self.moves.items) |*move| {
            if (move.source.equals(source)) {
                move.target = target;
                return;
            }
        }
        try self.moves.append(allocator, .{ .source = source, .target = target });
    }
};

const MovedPrecompileContext = struct {
    source: primitives.Address,
    fork: guillotine_mini.Hardfork,
};

const PreparedPrecompileOverrides = struct {
    contexts: []MovedPrecompileContext = &.{},
    overrides: []guillotine_mini.PrecompileOverride = &.{},

    fn deinit(self: *PreparedPrecompileOverrides, allocator: std.mem.Allocator) void {
        if (self.contexts.len != 0) allocator.free(self.contexts);
        if (self.overrides.len != 0) allocator.free(self.overrides);
    }
};

const SimulatedTransaction = struct {
    raw: []u8,
    hash: [32]u8,
    from: primitives.Address,
    to: ?primitives.Address,
    nonce: u64,
    gas: u64,
    value: u256,
    input: []u8,
    tx_type: u8,
    chain_id: ?u64,
    gas_price: ?u256,
    max_fee_per_gas: ?u256,
    max_priority_fee_per_gas: ?u256,
    max_fee_per_blob_gas: ?u256,
    access_list: []primitives.Transaction.AccessListItem,
    blob_versioned_hashes: [][32]u8,

    fn deinit(self: *SimulatedTransaction, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
        allocator.free(self.input);
        for (self.access_list) |entry| allocator.free(entry.storage_keys);
        if (self.access_list.len != 0) allocator.free(self.access_list);
        if (self.blob_versioned_hashes.len != 0) allocator.free(self.blob_versioned_hashes);
    }
};

const SimulatedTransfer = struct {
    from: primitives.Address,
    to: primitives.Address,
    value: u256,
};

const SimulatedBlockData = struct {
    block_ctx: guillotine_mini.BlockContext,
    parent_hash: [32]u8,
    block_hash: [32]u8,
    state_root: [32]u8,
    transactions_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    requests_hash: ?[32]u8,
    gas_used: u64,
    blob_gas_used: u64,
    size: u64,
    fork: guillotine_mini.Hardfork,
};

const SimulateBlockResult = struct {
    data: SimulatedBlockData,
    transactions: []SimulatedTransaction,

    fn deinit(self: *SimulateBlockResult, allocator: std.mem.Allocator) void {
        for (self.transactions) |*tx| tx.deinit(allocator);
        allocator.free(self.transactions);
    }
};

pub fn handleEthCall(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    clearLastExecutionErrorData();
    // NodeRuntime mode gating lives in dispatch_wiring so light mode can return
    // JSON-RPC -32010 before the trusted simulation path is entered.
    var parsed = try parseCallParams(allocator, params);
    defer parsed.deinit(allocator);

    const selected_block_number = try resolveTrustedBlockSelector(rt, parsed.block);
    try ensureCurrentStateSelector(rt, selected_block_number);
    var recent_block_hashes: [256][32]u8 = undefined;
    const block_ctx = try blockContext(rt, selected_block_number, &recent_block_hashes);

    try rt.state.checkpoint();
    defer rt.state.revert();

    if (parsed.state_overrides) |overrides| {
        try applyStateOverrides(allocator, rt, overrides, null, null);
    }

    var result = try executeOnce(allocator, rt, parsed.tx, block_ctx, gasLimit(parsed.tx, block_ctx));
    defer result.deinit(allocator);

    return hexBytes(allocator, result.output);
}

pub fn handleEthEstimateGas(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    clearLastExecutionErrorData();
    // NodeRuntime mode gating lives in dispatch_wiring so light mode can return
    // JSON-RPC -32010 before the trusted simulation path is entered.
    var parsed = try parseEstimateParams(allocator, params);
    defer parsed.deinit(allocator);

    const selected_block_number = if (parsed.block) |block|
        try resolveTrustedBlockSelector(rt, block)
    else
        rt.head_block_number;
    try ensureCurrentStateSelector(rt, selected_block_number);
    var recent_block_hashes: [256][32]u8 = undefined;
    const block_ctx = try blockContext(rt, selected_block_number, &recent_block_hashes);

    try rt.state.checkpoint();
    defer rt.state.revert();

    if (parsed.state_overrides) |overrides| {
        try applyStateOverrides(allocator, rt, overrides, null, null);
    }

    const estimate = try estimateGas(allocator, rt, parsed.tx, block_ctx);
    return hexQuantity(allocator, estimate);
}

pub fn handleEthCreateAccessList(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    clearLastExecutionErrorData();
    var parsed = try parseCreateAccessListParams(allocator, params);
    defer parsed.deinit(allocator);

    const selected_block_number = if (parsed.block) |block|
        try resolveTrustedBlockSelector(rt, block)
    else
        rt.head_block_number;
    try ensureCurrentStateSelector(rt, selected_block_number);
    var recent_block_hashes: [256][32]u8 = undefined;
    const block_ctx = try blockContext(rt, selected_block_number, &recent_block_hashes);

    try rt.state.checkpoint();
    defer rt.state.revert();

    var gas_used = intrinsicGas(rt, parsed.tx, block_ctx);
    var execution_error = false;
    if (estimateGas(allocator, rt, parsed.tx, block_ctx)) |estimate| {
        gas_used = estimate;
    } else |_| {
        if (executeOnce(allocator, rt, parsed.tx, block_ctx, gasLimit(parsed.tx, block_ctx))) |result| {
            var owned_result = result;
            defer owned_result.deinit(allocator);
            gas_used = owned_result.gas_used;
        } else |_| {
            execution_error = true;
        }
    }

    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &cleanup);
    }
    try putOwnedJsonValue(&obj, allocator, "accessList", .{ .array = std.json.Array.init(allocator) });
    try putOwnedJsonValue(&obj, allocator, "gasUsed", try hexQuantity(allocator, gas_used));
    if (execution_error) {
        try putOwnedJsonValue(&obj, allocator, "error", .{ .string = try allocator.dupe(u8, "execution reverted") });
    }
    return .{ .object = obj };
}

pub fn handleEthSimulateV1(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    clearLastExecutionErrorData();
    clearLastSimulationRpcError();
    const items = try paramsArrayItems(params);
    if (items.len < 1 or items.len > 2) return error.InvalidParams;
    const payload = switch (items[0]) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    const selected_block_number = if (items.len == 2)
        try resolveTrustedBlockSelector(rt, items[1])
    else
        rt.head_block_number;
    if (selected_block_number > rt.head_block_number) {
        setSimulationRpcErrorStatic(-32000, "header not found");
        return error.SimulationRpcError;
    }

    const block_state_calls = switch (payload.get("blockStateCalls") orelse return error.InvalidParams) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    if (block_state_calls.len > SIMULATE_MAX_BLOCK_STATE_CALLS) {
        setSimulationRpcErrorStatic(-38026, "too many blocks");
        return error.SimulationRpcError;
    }
    const options = SimulateOptions{
        .trace_transfers = try optionalBool(payload, "traceTransfers") orelse false,
        .validation = try optionalBool(payload, "validation") orelse false,
        .return_full_transactions = try optionalBool(payload, "returnFullTransactions") orelse false,
    };

    var field_it = payload.iterator();
    while (field_it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "blockStateCalls") or
            std.mem.eql(u8, entry.key_ptr.*, "traceTransfers") or
            std.mem.eql(u8, entry.key_ptr.*, "validation") or
            std.mem.eql(u8, entry.key_ptr.*, "returnFullTransactions"))
        {
            continue;
        }
        return error.InvalidParams;
    }

    var restore_live_state = false;
    var live_state: @TypeOf(rt.state) = undefined;
    if (selected_block_number == rt.head_block_number) {
        try rt.state.checkpoint();
    } else {
        const historical = try rt.replayStateToBlock(selected_block_number);
        live_state = rt.state;
        rt.state = historical;
        restore_live_state = true;
    }
    defer {
        if (restore_live_state) {
            rt.state.deinit();
            rt.state = live_state;
        } else {
            rt.state.revert();
        }
    }

    var recent_block_hashes: [256][32]u8 = undefined;
    const parent_ctx = try blockContext(rt, selected_block_number, &recent_block_hashes);
    var parent_hash = rt.blockchain.getCanonicalHash(selected_block_number) orelse [_]u8{0} ** 32;
    var parent_header = if (try rt.blockchain.getBlockByNumber(selected_block_number)) |block|
        block.header
    else
        primitives.BlockHeader.BlockHeader{
            .parent_hash = [_]u8{0} ** 32,
            .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
            .beneficiary = parent_ctx.block_coinbase,
            .state_root = block_builder.computeStateRootForFork(allocator, &rt.state, simBlockBuilderFork(rt.hardforkForBlockContext(parent_ctx))) catch primitives.State.EMPTY_TRIE_ROOT,
            .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
            .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
            .difficulty = parent_ctx.block_difficulty,
            .number = parent_ctx.block_number,
            .gas_limit = parent_ctx.block_gas_limit,
            .gas_used = 0,
            .timestamp = parent_ctx.block_timestamp,
            .mix_hash = intToHash(parent_ctx.block_prevrandao),
            .base_fee_per_gas = if (rt.hardforkForBlockContext(parent_ctx).isAtLeast(.LONDON)) parent_ctx.block_base_fee else null,
            .withdrawals_root = if (rt.hardforkForBlockContext(parent_ctx).isAtLeast(.SHANGHAI)) primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT else null,
            .blob_gas_used = if (rt.hardforkForBlockContext(parent_ctx).isAtLeast(.CANCUN)) 0 else null,
            .excess_blob_gas = if (rt.hardforkForBlockContext(parent_ctx).isAtLeast(.CANCUN)) 0 else null,
            .parent_beacon_block_root = if (rt.hardforkForBlockContext(parent_ctx).isAtLeast(.CANCUN)) primitives.Hash.ZERO else null,
        };
    var next_ctx = try nextSimulatedBlockContext(rt, parent_ctx, parent_header, options.validation);
    next_ctx.block_hashes = appendRecentBlockHash(&recent_block_hashes, parent_ctx.block_hashes, parent_hash);
    var remaining_default_gas: u64 = SIMULATE_DEFAULT_GAS_CAP;
    var nonce_tracker = std.ArrayList(SimulatedNonceState){};
    defer nonce_tracker.deinit(allocator);
    var precompile_moves = PrecompileMoveState{};
    defer precompile_moves.deinit(allocator);

    var blocks = std.json.Array.init(allocator);
    errdefer {
        for (blocks.items) |*item| deinitJsonValue(allocator, item);
        blocks.deinit();
    }

    for (block_state_calls) |block_value| {
        const block_request = switch (block_value) {
            .object => |object| object,
            else => return error.InvalidParams,
        };

        const block_overrides = if (block_request.get("blockOverrides")) |overrides|
            try parseBlockOverrides(overrides)
        else
            BlockOverrides{};
        var target_ctx = next_ctx;
        if (block_overrides.number) |number| target_ctx.block_number = number;
        while (target_ctx.block_number > next_ctx.block_number) {
            var empty_calls = std.json.Array.init(allocator);
            var simulated = try simulateBlock(allocator, rt, next_ctx, parent_hash, null, &[_]std.json.Value{}, options, &empty_calls, &remaining_default_gas, &nonce_tracker, &precompile_moves);
            defer simulated.deinit(allocator);
            try blocks.append(try simulatedBlockValue(allocator, simulated.data, empty_calls, simulated.transactions, options.return_full_transactions));
            parent_hash = simulated.data.block_hash;
            parent_header = headerFromSimulatedBlock(simulated.data);
            next_ctx = try nextSimulatedBlockContext(rt, simulated.data.block_ctx, parent_header, options.validation);
            next_ctx.block_hashes = appendRecentBlockHash(&recent_block_hashes, simulated.data.block_ctx.block_hashes, simulated.data.block_hash);
        }
        target_ctx = next_ctx;
        if (block_overrides.number) |number| target_ctx.block_number = number;
        if (target_ctx.block_number <= parent_header.number) {
            setSimulationRpcErrorStatic(-38020, "block number must be greater than parent block number");
            return error.SimulationRpcError;
        }
        applyBlockOverridesToContext(&target_ctx, block_overrides);
        if (target_ctx.block_timestamp <= parent_header.timestamp) {
            setSimulationRpcErrorFmt(-38021, "block timestamps must be in order: {d} <= {d}", .{ target_ctx.block_timestamp, parent_header.timestamp });
            return error.SimulationRpcError;
        }

        const calls = if (block_request.get("calls")) |calls_value|
            try arrayItemsValue(calls_value)
        else
            &[_]std.json.Value{};

        var call_results = std.json.Array.init(allocator);
        var simulated = try simulateBlock(
            allocator,
            rt,
            target_ctx,
            parent_hash,
            block_request.get("stateOverrides"),
            calls,
            options,
            &call_results,
            &remaining_default_gas,
            &nonce_tracker,
            &precompile_moves,
        );
        defer simulated.deinit(allocator);
        try blocks.append(try simulatedBlockValue(allocator, simulated.data, call_results, simulated.transactions, options.return_full_transactions));
        parent_hash = simulated.data.block_hash;
        parent_header = headerFromSimulatedBlock(simulated.data);
        next_ctx = try nextSimulatedBlockContext(rt, simulated.data.block_ctx, parent_header, options.validation);
        next_ctx.block_hashes = appendRecentBlockHash(&recent_block_hashes, simulated.data.block_ctx.block_hashes, simulated.data.block_hash);
    }

    return .{ .array = blocks };
}

pub fn takeLastExecutionErrorData() ?[]const u8 {
    const data = last_execution_error_data;
    last_execution_error_data = null;
    return data;
}

pub fn takeLastSimulationRpcError() ?SimulationRpcError {
    const err = last_simulation_rpc_error;
    last_simulation_rpc_error = null;
    return err;
}

fn clearLastExecutionErrorData() void {
    last_execution_error_data = null;
}

fn clearLastSimulationRpcError() void {
    last_simulation_rpc_error = null;
}

fn setSimulationRpcErrorStatic(code: i32, message: []const u8) void {
    const len = @min(message.len, last_simulation_rpc_error_message_buf.len);
    @memcpy(last_simulation_rpc_error_message_buf[0..len], message[0..len]);
    last_simulation_rpc_error = .{
        .code = code,
        .message = last_simulation_rpc_error_message_buf[0..len],
    };
}

fn setSimulationRpcErrorFmt(code: i32, comptime fmt: []const u8, args: anytype) void {
    const message = std.fmt.bufPrint(&last_simulation_rpc_error_message_buf, fmt, args) catch "simulation error";
    last_simulation_rpc_error = .{ .code = code, .message = message };
}

fn parseCallParams(allocator: std.mem.Allocator, params: ?std.json.Value) !ParsedCallParams {
    const items = try paramsArrayItems(params);
    if (items.len != 2 and items.len != 3) return error.InvalidParams;

    return .{
        .tx = try parseTransactionRequest(allocator, items[0]),
        .block = items[1],
        .state_overrides = if (items.len == 3) items[2] else null,
    };
}

fn parseEstimateParams(allocator: std.mem.Allocator, params: ?std.json.Value) !ParsedEstimateParams {
    const items = try paramsArrayItems(params);
    if (items.len < 1 or items.len > 3) return error.InvalidParams;

    return .{
        .tx = try parseTransactionRequest(allocator, items[0]),
        .block = if (items.len >= 2) items[1] else null,
        .state_overrides = if (items.len == 3) items[2] else null,
    };
}

fn parseCreateAccessListParams(allocator: std.mem.Allocator, params: ?std.json.Value) !ParsedCreateAccessListParams {
    const items = try paramsArrayItems(params);
    if (items.len < 1 or items.len > 2) return error.InvalidParams;

    return .{
        .tx = try parseTransactionRequest(allocator, items[0]),
        .block = if (items.len == 2) items[1] else null,
    };
}

fn paramsArrayItems(params: ?std.json.Value) ![]const std.json.Value {
    return rpc_parse.paramsArrayItems(params);
}

fn parseTransactionRequest(allocator: std.mem.Allocator, value: std.json.Value) !TransactionRequest {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidParams,
    };

    var tx = TransactionRequest{
        .data = try allocator.alloc(u8, 0),
    };
    errdefer tx.deinit(allocator);

    var data_value: ?[]u8 = null;
    var input_value: ?[]u8 = null;
    errdefer {
        if (data_value) |bytes| allocator.free(bytes);
        if (input_value) |bytes| allocator.free(bytes);
    }

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const field = entry.value_ptr.*;

        if (std.mem.eql(u8, key, "from")) {
            tx.from = try parseAddressValue(field);
        } else if (std.mem.eql(u8, key, "to")) {
            tx.to = switch (field) {
                .null => null,
                else => try parseAddressValue(field),
            };
        } else if (std.mem.eql(u8, key, "gas")) {
            tx.gas = try parseQuantityU64Value(field);
        } else if (std.mem.eql(u8, key, "gasPrice")) {
            tx.gas_price = try parseQuantityU256Value(field);
            tx.has_fee_fields = true;
        } else if (std.mem.eql(u8, key, "maxFeePerGas")) {
            tx.max_fee_per_gas = try parseQuantityU256Value(field);
            tx.has_fee_fields = true;
        } else if (std.mem.eql(u8, key, "maxPriorityFeePerGas")) {
            tx.max_priority_fee_per_gas = try parseQuantityU256Value(field);
            tx.has_fee_fields = true;
        } else if (std.mem.eql(u8, key, "maxFeePerBlobGas")) {
            tx.max_fee_per_blob_gas = try parseQuantityU256Value(field);
        } else if (std.mem.eql(u8, key, "value")) {
            tx.value = try parseQuantityU256Value(field);
        } else if (std.mem.eql(u8, key, "nonce")) {
            tx.nonce = try parseQuantityU64Value(field);
        } else if (std.mem.eql(u8, key, "chainId")) {
            tx.chain_id = try parseQuantityU64Value(field);
        } else if (std.mem.eql(u8, key, "type")) {
            const tx_type = try parseQuantityLikeValue(field);
            if (tx_type > std.math.maxInt(u8)) return error.InvalidParams;
            tx.tx_type = @intCast(tx_type);
        } else if (std.mem.eql(u8, key, "accessList")) {
            try parseAccessList(allocator, field, &tx);
        } else if (std.mem.eql(u8, key, "blobVersionedHashes") or
            std.mem.eql(u8, key, "blobs") or
            std.mem.eql(u8, key, "commitments") or
            std.mem.eql(u8, key, "proofs"))
        {
            if (std.mem.eql(u8, key, "blobVersionedHashes")) {
                try parseBlobVersionedHashes(allocator, field, &tx);
            } else {
                _ = try arrayItemsValue(field);
            }
        } else if (std.mem.eql(u8, key, "authorizationList")) {
            _ = try arrayItemsValue(field);
        } else if (std.mem.eql(u8, key, "data")) {
            if (data_value != null) return error.InvalidParams;
            data_value = try parseHexDataValue(allocator, field);
        } else if (std.mem.eql(u8, key, "input")) {
            if (input_value != null) return error.InvalidParams;
            input_value = try parseHexDataValue(allocator, field);
        } else {
            return error.InvalidParams;
        }
    }

    if (data_value != null and input_value != null) {
        if (!std.mem.eql(u8, data_value.?, input_value.?)) return error.InvalidParams;
        allocator.free(tx.data);
        tx.data = data_value.?;
        data_value = null;
        allocator.free(input_value.?);
        input_value = null;
    } else if (data_value) |bytes| {
        allocator.free(tx.data);
        tx.data = bytes;
        data_value = null;
    } else if (input_value) |bytes| {
        allocator.free(tx.data);
        tx.data = bytes;
        input_value = null;
    }

    return tx;
}

fn parseAccessList(allocator: std.mem.Allocator, value: std.json.Value, tx: *TransactionRequest) !void {
    const entries = try arrayItemsValue(value);
    if (tx.access_list.len != 0) return error.InvalidParams;
    const access_list = try allocator.alloc(primitives.Transaction.AccessListItem, entries.len);
    errdefer {
        for (access_list) |entry| allocator.free(entry.storage_keys);
        allocator.free(access_list);
    }
    const processor_access_list = try allocator.alloc(primitives.AccessList.AccessListEntry, entries.len);
    errdefer allocator.free(processor_access_list);

    tx.access_list_addresses = @intCast(entries.len);
    tx.access_list_storage_keys = 0;
    for (entries, 0..) |entry_value, i| {
        const entry = switch (entry_value) {
            .object => |object| object,
            else => return error.InvalidParams,
        };
        const address = try parseAddressValue(entry.get("address") orelse return error.InvalidParams);
        const storage_keys = try arrayItemsValue(entry.get("storageKeys") orelse return error.InvalidParams);
        const keys = try allocator.alloc([32]u8, storage_keys.len);
        errdefer allocator.free(keys);
        for (storage_keys, 0..) |slot, key_index| {
            keys[key_index] = try rpc_parse.parseHash32Value(slot);
        }
        tx.access_list_storage_keys += @intCast(storage_keys.len);
        access_list[i] = .{ .address = address, .storage_keys = keys };
        processor_access_list[i] = .{ .address = address, .storage_keys = keys };
    }
    tx.access_list = access_list;
    tx.processor_access_list = processor_access_list;
}

fn parseBlobVersionedHashes(allocator: std.mem.Allocator, value: std.json.Value, tx: *TransactionRequest) !void {
    const items = try arrayItemsValue(value);
    if (tx.blob_versioned_hashes.len != 0) return error.InvalidParams;
    const hashes = try allocator.alloc([32]u8, items.len);
    errdefer allocator.free(hashes);
    for (items, 0..) |item, i| {
        hashes[i] = try rpc_parse.parseHash32Value(item);
    }
    tx.blob_versioned_hashes = hashes;
}

fn parseQuantityLikeValue(value: std.json.Value) !u256 {
    return parseQuantityU256Value(value);
}

fn arrayItemsValue(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidParams,
    };
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) !?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidParams,
    };
}

const BlockOverrides = struct {
    number: ?u64 = null,
    timestamp: ?u64 = null,
    gas_limit: ?u64 = null,
    fee_recipient: ?primitives.Address = null,
    prev_randao: ?u256 = null,
    base_fee_per_gas: ?u256 = null,
    blob_base_fee: ?u256 = null,
};

fn parseBlockOverrides(value: std.json.Value) !BlockOverrides {
    const object = switch (value) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };

    var out = BlockOverrides{};
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const field = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "number")) {
            out.number = try parseQuantityU64Value(field);
        } else if (std.mem.eql(u8, key, "time") or std.mem.eql(u8, key, "timestamp")) {
            out.timestamp = try parseQuantityU64Value(field);
        } else if (std.mem.eql(u8, key, "gasLimit")) {
            out.gas_limit = try parseQuantityU64Value(field);
        } else if (std.mem.eql(u8, key, "feeRecipient")) {
            out.fee_recipient = try parseAddressValue(field);
        } else if (std.mem.eql(u8, key, "baseFeePerGas")) {
            out.base_fee_per_gas = try parseQuantityU256Value(field);
        } else if (std.mem.eql(u8, key, "blobBaseFee")) {
            out.blob_base_fee = try parseQuantityU256Value(field);
        } else if (std.mem.eql(u8, key, "prevRandao")) {
            out.prev_randao = try parsePrevRandaoValue(field);
        } else if (std.mem.eql(u8, key, "withdrawals")) {
            _ = try arrayItemsValue(field);
        } else {
            return error.InvalidParams;
        }
    }
    return out;
}

fn applyBlockOverridesToContext(block_ctx: *guillotine_mini.BlockContext, overrides: BlockOverrides) void {
    if (overrides.number) |number| block_ctx.block_number = number;
    if (overrides.timestamp) |timestamp| block_ctx.block_timestamp = timestamp;
    if (overrides.gas_limit) |gas_limit| block_ctx.block_gas_limit = gas_limit;
    if (overrides.fee_recipient) |fee_recipient| block_ctx.block_coinbase = fee_recipient;
    if (overrides.base_fee_per_gas) |base_fee| block_ctx.block_base_fee = base_fee;
    if (overrides.blob_base_fee) |blob_base_fee| block_ctx.blob_base_fee = blob_base_fee;
    if (overrides.prev_randao) |prev_randao| block_ctx.block_prevrandao = prev_randao;
}

fn applyBlockOverrides(block_ctx: *guillotine_mini.BlockContext, value: std.json.Value) !void {
    const object = switch (value) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };

    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const field = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "number")) {
            block_ctx.block_number = try parseQuantityU64Value(field);
        } else if (std.mem.eql(u8, key, "time") or std.mem.eql(u8, key, "timestamp")) {
            block_ctx.block_timestamp = try parseQuantityU64Value(field);
        } else if (std.mem.eql(u8, key, "gasLimit")) {
            block_ctx.block_gas_limit = try parseQuantityU64Value(field);
        } else if (std.mem.eql(u8, key, "feeRecipient")) {
            block_ctx.block_coinbase = try parseAddressValue(field);
        } else if (std.mem.eql(u8, key, "baseFeePerGas")) {
            block_ctx.block_base_fee = try parseQuantityU256Value(field);
        } else if (std.mem.eql(u8, key, "blobBaseFee")) {
            block_ctx.blob_base_fee = try parseQuantityU256Value(field);
        } else if (std.mem.eql(u8, key, "prevRandao")) {
            block_ctx.block_prevrandao = try parsePrevRandaoValue(field);
        } else if (std.mem.eql(u8, key, "withdrawals")) {
            _ = try arrayItemsValue(field);
        } else {
            return error.InvalidParams;
        }
    }
}

fn resolveTrustedBlockSelector(rt: *const runtime.NodeRuntime, value: std.json.Value) !u64 {
    return rpc_parse.resolveTrustedBlockSelector(rt.head_block_number, value);
}

fn ensureCurrentStateSelector(rt: *const runtime.NodeRuntime, block_number: u64) !void {
    if (block_number != rt.head_block_number) return error.InvalidParams;
}

fn applyStateOverrides(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    value: std.json.Value,
    precompile_moves: ?*PrecompileMoveState,
    fork: ?guillotine_mini.Hardfork,
) !void {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidParams,
    };

    var accounts = object.iterator();
    while (accounts.next()) |entry| {
        const address = try parseAddressString(entry.key_ptr.*);
        const account_override = switch (entry.value_ptr.*) {
            .object => |override_object| override_object,
            else => return error.InvalidParams,
        };

        var fields = account_override.iterator();
        while (fields.next()) |field| {
            const field_name = field.key_ptr.*;
            const field_value = field.value_ptr.*;

            if (std.mem.eql(u8, field_name, "balance")) {
                try rt.state.setBalance(address, try parseQuantityU256Value(field_value));
            } else if (std.mem.eql(u8, field_name, "nonce")) {
                try rt.state.setNonce(address, try parseQuantityU64Value(field_value));
            } else if (std.mem.eql(u8, field_name, "code")) {
                const code = try parseHexDataValue(allocator, field_value);
                defer allocator.free(code);
                try rt.state.setCode(address, code);
            } else if (std.mem.eql(u8, field_name, "storage")) {
                try applyStorageOverrides(rt, address, field_value);
            } else if (std.mem.eql(u8, field_name, "state")) {
                try clearAccountStorage(rt, address);
                try applyStorageOverrides(rt, address, field_value);
            } else if (std.mem.eql(u8, field_name, "stateDiff")) {
                try applyStorageOverrides(rt, address, field_value);
            } else if (std.mem.eql(u8, field_name, "movePrecompileToAddress")) {
                const target = try parseAddressValue(field_value);
                if (precompile_moves) |moves| {
                    try moves.apply(allocator, address, target, fork orelse rt.hardforkForBlockContext(guillotine_mini.BlockContext{
                        .chain_id = rt.chain_id,
                        .block_number = rt.head_block_number,
                        .block_timestamp = rt.head_block_timestamp,
                        .block_difficulty = 0,
                        .block_prevrandao = 0,
                        .block_coinbase = rt.coinbase,
                        .block_gas_limit = rt.dev_runtime.config.block_gas_limit,
                        .block_base_fee = rt.base_fee,
                        .blob_base_fee = rt.blob_base_fee,
                    }));
                }
            } else {
                return error.InvalidParams;
            }
        }
    }
}

fn applyStorageOverrides(
    rt: *runtime.NodeRuntime,
    address: primitives.Address,
    value: std.json.Value,
) !void {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidParams,
    };

    var slots = object.iterator();
    while (slots.next()) |entry| {
        const slot = try parseBytes32U256(entry.key_ptr.*);
        const slot_value = switch (entry.value_ptr.*) {
            .string => |text| try parseBytes32U256(text),
            else => return error.InvalidParams,
        };
        try rt.state.setStorage(address, slot, slot_value);
    }
}

fn clearAccountStorage(
    rt: *runtime.NodeRuntime,
    address: primitives.Address,
) !void {
    if (rt.state.journaled_state.storage_cache.cache.fetchRemove(address)) |entry| {
        var slots = entry.value;
        slots.deinit();
    }
    var account = rt.state.journaled_state.account_cache.get(address) orelse return;
    account.storage_root = primitives.State.EMPTY_TRIE_ROOT;
    try rt.state.journaled_state.account_cache.put(address, account);
}

fn appendRecentBlockHash(
    out: *[256][32]u8,
    current: []const [32]u8,
    hash: [32]u8,
) []const [32]u8 {
    const current_len = @min(current.len, out.len);
    if (current_len != 0 and @intFromPtr(current.ptr) != @intFromPtr(&out[0])) {
        std.mem.copyForwards([32]u8, out[0..current_len], current[0..current_len]);
    }
    if (current_len < out.len) {
        out[current_len] = hash;
        return out[0 .. current_len + 1];
    }

    std.mem.copyForwards([32]u8, out[0 .. out.len - 1], out[1..out.len]);
    out[out.len - 1] = hash;
    return out[0..out.len];
}

fn nextSimulatedBlockContext(
    rt: *runtime.NodeRuntime,
    parent_ctx: guillotine_mini.BlockContext,
    parent_header: primitives.BlockHeader.BlockHeader,
    validation: bool,
) !guillotine_mini.BlockContext {
    var ctx = parent_ctx;
    ctx.block_number = try std.math.add(u64, parent_header.number, 1);
    ctx.block_timestamp = try std.math.add(u64, parent_header.timestamp, SIMULATE_BLOCK_TIME_INCREMENT);
    ctx.block_gas_limit = parent_header.gas_limit;
    ctx.block_base_fee = if (validation)
        block_builder.expectedBaseFeePerGas(&parent_header) catch parent_ctx.block_base_fee
    else
        0;
    const child_fork = rt.hardforkAt(ctx.block_number, ctx.block_timestamp);
    if (child_fork.isBefore(.MERGE)) {
        ctx.block_difficulty = parent_header.difficulty;
        ctx.block_prevrandao = 0;
    } else {
        ctx.block_difficulty = 0;
        ctx.block_prevrandao = 0;
    }
    return ctx;
}

fn preparePrecompileOverrides(
    allocator: std.mem.Allocator,
    moves: []const PrecompileMove,
    fork: guillotine_mini.Hardfork,
) !PreparedPrecompileOverrides {
    if (moves.len == 0) return .{};

    var contexts = try allocator.alloc(MovedPrecompileContext, moves.len);
    errdefer allocator.free(contexts);
    const overrides = try allocator.alloc(guillotine_mini.PrecompileOverride, moves.len * 2);
    errdefer allocator.free(overrides);

    for (moves, 0..) |move, i| {
        contexts[i] = .{ .source = move.source, .fork = fork };
        overrides[i * 2] = .{
            .address = move.target,
            .execute = executeMovedPrecompile,
            .context = &contexts[i],
        };
        overrides[i * 2 + 1] = .{
            .address = move.source,
            .execute = executeDisabledPrecompile,
            .context = null,
        };
    }

    return .{ .contexts = contexts, .overrides = overrides };
}

fn executeMovedPrecompile(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) anyerror!guillotine_mini.PrecompileOutput {
    const moved: *const MovedPrecompileContext = @ptrCast(@alignCast(ctx.?));
    return precompile_compat.execute(allocator, moved.source, input, gas_limit, moved.fork);
}

fn executeDisabledPrecompile(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) anyerror!guillotine_mini.PrecompileOutput {
    _ = ctx;
    _ = allocator;
    _ = input;
    _ = gas_limit;
    return .{
        .output = &.{},
        .gas_used = 0,
        .success = true,
    };
}

fn simulateBlock(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    block_ctx: guillotine_mini.BlockContext,
    parent_hash: [32]u8,
    state_overrides: ?std.json.Value,
    calls: []const std.json.Value,
    options: SimulateOptions,
    call_results: *std.json.Array,
    remaining_default_gas: *u64,
    nonce_tracker: *std.ArrayList(SimulatedNonceState),
    precompile_moves: *PrecompileMoveState,
) !SimulateBlockResult {
    const fork = rt.hardforkForBlockContext(block_ctx);
    if (state_overrides) |overrides| {
        try applyStateOverrides(allocator, rt, overrides, precompile_moves, fork);
    }
    var prepared_precompile_overrides = try preparePrecompileOverrides(allocator, precompile_moves.moves.items, fork);
    defer prepared_precompile_overrides.deinit(allocator);

    if (fork.isAtLeast(.CANCUN)) {
        try block_builder.applyBeaconRootsSystemCall(&rt.state, block_ctx.block_timestamp, primitives.Hash.ZERO);
    }
    if (fork.isAtLeast(.PRAGUE)) {
        try block_builder.applyHistoricalBlockHashSystemCall(&rt.state, block_ctx.block_number, parent_hash);
    }
    var preserved_empty_accounts = if (fork.isAtLeast(.BYZANTIUM))
        try block_builder.collectEmptyAccounts(allocator, &rt.state)
    else
        null;
    defer if (preserved_empty_accounts) |*accounts| accounts.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &rt.state };
    const host = adapter.hostInterface();

    var receipts = std.ArrayList(primitives.Receipt.Receipt){};
    defer {
        for (receipts.items) |receipt| receipt.deinit(allocator);
        receipts.deinit(allocator);
    }
    var outputs = std.ArrayList([]u8){};
    defer {
        for (outputs.items) |output| allocator.free(output);
        outputs.deinit(allocator);
    }
    var transfer_sets = std.ArrayList([]SimulatedTransfer){};
    defer {
        for (transfer_sets.items) |transfers| allocator.free(transfers);
        transfer_sets.deinit(allocator);
    }
    var transactions = std.ArrayList(SimulatedTransaction){};
    errdefer {
        for (transactions.items) |*tx| tx.deinit(allocator);
        transactions.deinit(allocator);
    }
    var raw_txs = std.ArrayList(primitives.BlockBody.TransactionData){};
    defer raw_txs.deinit(allocator);

    var gas_used: u64 = 0;
    var blob_gas_used: u64 = 0;

    for (calls) |call_value| {
        var request = try parseTransactionRequest(allocator, call_value);
        defer request.deinit(allocator);

        const remaining_block_gas = if (gas_used >= block_ctx.block_gas_limit) 0 else block_ctx.block_gas_limit - gas_used;
        const call_gas = request.gas orelse @min(remaining_default_gas.*, remaining_block_gas);
        if (call_gas > remaining_block_gas) {
            setSimulationRpcErrorStatic(-38015, "block gas limit exceeded");
            return error.SimulationRpcError;
        }

        var simulated_tx = try buildSimulatedTransaction(allocator, rt, request, block_ctx, call_gas, options, nonce_tracker);
        errdefer simulated_tx.deinit(allocator);

        var output: []u8 = &.{};
        var balance_changes = std.ArrayList(host_adapter.HostAdapter.BalanceChange){};
        defer balance_changes.deinit(allocator);
        if (options.trace_transfers) {
            adapter.balance_change_allocator = allocator;
            adapter.balance_changes = &balance_changes;
        }
        var receipt = processSimulatedTransaction(allocator, rt, &adapter, host, simulated_tx, block_ctx, options, prepared_precompile_overrides.overrides, &output) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SimulationRpcError => return error.SimulationRpcError,
            else => return err,
        };
        adapter.balance_change_allocator = null;
        adapter.balance_changes = null;
        errdefer {
            adapter.balance_change_allocator = null;
            adapter.balance_changes = null;
            receipt.deinit(allocator);
            allocator.free(output);
        }

        const tx_gas_used = std.math.cast(u64, receipt.gas_used) orelse return error.InvalidParams;
        gas_used = std.math.add(u64, gas_used, tx_gas_used) catch {
            setSimulationRpcErrorStatic(-38015, "block gas limit exceeded");
            return error.SimulationRpcError;
        };
        if (gas_used > block_ctx.block_gas_limit) {
            setSimulationRpcErrorStatic(-38015, "block gas limit exceeded");
            return error.SimulationRpcError;
        }
        if (receipt.blob_gas_used) |receipt_blob_gas| {
            const receipt_blob_gas_u64 = std.math.cast(u64, receipt_blob_gas) orelse return error.InvalidParams;
            blob_gas_used = std.math.add(u64, blob_gas_used, receipt_blob_gas_u64) catch return error.InvalidParams;
        }
        remaining_default_gas.* = if (remaining_default_gas.* > tx_gas_used) remaining_default_gas.* - tx_gas_used else 0;

        receipt.transaction_hash = simulated_tx.hash;
        receipt.transaction_index = @intCast(receipts.items.len);
        receipt.block_number = block_ctx.block_number;
        receipt.cumulative_gas_used = @as(u256, gas_used);
        const mutable_logs = @constCast(receipt.logs);
        for (mutable_logs, 0..) |*event_log, log_index| {
            event_log.block_number = block_ctx.block_number;
            event_log.transaction_hash = simulated_tx.hash;
            event_log.transaction_index = receipt.transaction_index;
            event_log.log_index = @intCast(log_index);
        }

        const tx_success = if (receipt.status) |status| status.success else true;
        const transfers = if (options.trace_transfers and tx_success)
            try simulatedTransfersFromBalanceChanges(allocator, balance_changes.items)
        else
            try allocator.alloc(SimulatedTransfer, 0);
        var transfers_owned = true;
        errdefer if (transfers_owned) allocator.free(transfers);

        try raw_txs.append(allocator, .{ .raw = simulated_tx.raw });
        try outputs.append(allocator, output);
        output = &.{};
        try receipts.append(allocator, receipt);
        try transfer_sets.append(allocator, transfers);
        transfers_owned = false;
        try transactions.append(allocator, simulated_tx);
    }

    const receipts_root = try block_builder.computeReceiptsRoot(allocator, receipts.items);
    const transactions_root = try block_builder.computeRawTransactionsRoot(allocator, raw_txs.items);
    const logs_bloom = block_builder.aggregateLogsBloom(receipts.items);
    if (preserved_empty_accounts) |*accounts| {
        try block_builder.pruneNewEmptyAccounts(allocator, &rt.state, accounts);
    }
    var system_requests = if (fork.isAtLeast(.PRAGUE))
        try block_builder.collectPragueRequestsSystemCalls(
            allocator,
            &rt.state,
            host,
            block_ctx,
            fork,
        )
    else
        block_builder.PragueSystemRequests{};
    defer system_requests.deinit(allocator);
    const builder_fork = simBlockBuilderFork(fork);
    if (fork.isBefore(.MERGE)) {
        try block_builder.applyMinerReward(&rt.state, block_ctx.block_coinbase, builder_fork);
    }
    const state_root = try block_builder.computeStateRootForFork(allocator, &rt.state, builder_fork);
    const requests_hash = if (fork.isAtLeast(.PRAGUE))
        block_builder.computeRequestsHash(.{
            .withdrawals = system_requests.withdrawals orelse &.{},
            .consolidations = system_requests.consolidations orelse &.{},
        })
    else
        null;

    var header = simulatedHeader(block_ctx, parent_hash, state_root, transactions_root, receipts_root, logs_bloom, gas_used, blob_gas_used, fork);
    const block_hash = try block_builder.computeHeaderHashWithRequestsHash(allocator, &header, requests_hash);
    header = simulatedHeader(block_ctx, parent_hash, state_root, transactions_root, receipts_root, logs_bloom, gas_used, blob_gas_used, fork);
    for (receipts.items) |*receipt| {
        receipt.block_hash = block_hash;
        var global_log_index: u32 = 0;
        for (receipts.items[0..receipt.transaction_index]) |prior| {
            global_log_index += @intCast(prior.logs.len);
        }
        const mutable_logs = @constCast(receipt.logs);
        for (mutable_logs, 0..) |*event_log, offset| {
            event_log.log_index = global_log_index + @as(u32, @intCast(offset));
        }
    }

    for (receipts.items, outputs.items, transactions.items, transfer_sets.items) |receipt, output, tx, transfers| {
        try call_results.append(try simulateCallValueFromReceipt(allocator, receipt, output, tx, transfers, options, block_ctx.block_timestamp));
    }

    const size = try simulatedBlockSize(allocator, header, requests_hash, raw_txs.items, fork);
    const owned_transactions = try transactions.toOwnedSlice(allocator);
    transactions = std.ArrayList(SimulatedTransaction){};
    return .{
        .data = .{
            .block_ctx = block_ctx,
            .parent_hash = parent_hash,
            .block_hash = block_hash,
            .state_root = state_root,
            .transactions_root = transactions_root,
            .receipts_root = receipts_root,
            .logs_bloom = logs_bloom,
            .requests_hash = requests_hash,
            .gas_used = gas_used,
            .blob_gas_used = blob_gas_used,
            .size = size,
            .fork = fork,
        },
        .transactions = owned_transactions,
    };
}

fn processSimulatedTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    adapter: *host_adapter.HostAdapter,
    host: guillotine_mini.HostInterface,
    simulated_tx: SimulatedTransaction,
    block_ctx: guillotine_mini.BlockContext,
    options: SimulateOptions,
    precompile_overrides: []const guillotine_mini.PrecompileOverride,
    output: *[]u8,
) !primitives.Receipt.Receipt {
    _ = adapter;
    const legacy_tx = primitives.Transaction.LegacyTransaction{
        .nonce = simulated_tx.nonce,
        .gas_price = simulated_tx.max_fee_per_gas orelse simulated_tx.gas_price orelse 0,
        .gas_limit = simulated_tx.gas,
        .to = simulated_tx.to,
        .value = simulated_tx.value,
        .data = simulated_tx.input,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    const receipt_type: primitives.Receipt.TransactionType = switch (simulated_tx.tx_type) {
        0 => .legacy,
        1 => .eip2930,
        2 => .eip1559,
        3 => .eip4844,
        4 => .eip7702,
        else => {
            setSimulationRpcErrorStatic(-32602, "unsupported transaction type");
            return error.SimulationRpcError;
        },
    };
    const processor_access_list = try accessListForProcessor(allocator, simulated_tx.access_list);
    defer allocator.free(processor_access_list);
    const process_options = tx_processor.ProcessTransactionOptions{
        .access_list = if (processor_access_list.len == 0) null else processor_access_list,
        .receipt_type = receipt_type,
        .max_fee_per_gas = simulated_tx.max_fee_per_gas,
        .max_priority_fee_per_gas = simulated_tx.max_priority_fee_per_gas,
        .blob_gas_used = if (receipt_type == .eip4844) @as(u256, simulated_tx.blob_versioned_hashes.len) * @as(u256, 131_072) else null,
        .blob_gas_price = if (receipt_type == .eip4844) block_ctx.blob_base_fee else null,
        .max_fee_per_blob_gas = simulated_tx.max_fee_per_blob_gas,
        .blob_versioned_hashes = if (receipt_type == .eip4844) simulated_tx.blob_versioned_hashes else null,
        .precompile_overrides = precompile_overrides,
        .hardfork_override = rt.hardforkForBlockContext(block_ctx),
        .skip_sender_eoa_check = true,
        .skip_nonce_validation = true,
        .skip_fee_validation = !options.validation,
        .skip_fee_balance_check = !options.validation,
        .skip_nonce_state_increment = false,
        .capture_output = output,
    };
    return tx_processor.processTransactionWithOptions(
        allocator,
        &rt.state,
        host,
        simulated_tx.from,
        legacy_tx,
        block_ctx,
        process_options,
    ) catch |err| switch (err) {
        error.IntrinsicGasExceedsLimit => {
            setSimulationRpcErrorStatic(-38013, "intrinsic gas too low");
            return error.SimulationRpcError;
        },
        error.BlockGasLimitExceeded => {
            setSimulationRpcErrorStatic(-38015, "block gas limit exceeded");
            return error.SimulationRpcError;
        },
        error.InsufficientBalance => {
            setSimulationRpcErrorStatic(-38014, "insufficient funds");
            return error.SimulationRpcError;
        },
        error.GasPriceBelowBaseFee => {
            setSimulationRpcErrorStatic(-32602, "err: max fee per gas less than block base fee");
            return error.SimulationRpcError;
        },
        error.TipExceedsFeeCap, error.NonceMismatch => {
            setSimulationRpcErrorStatic(-32602, "Invalid params");
            return error.SimulationRpcError;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setSimulationRpcErrorStatic(-32000, "execution failed");
            return error.SimulationRpcError;
        },
    };
}

fn accessListForProcessor(
    allocator: std.mem.Allocator,
    access_list: []const primitives.Transaction.AccessListItem,
) ![]primitives.AccessList.AccessListEntry {
    const entries = try allocator.alloc(primitives.AccessList.AccessListEntry, access_list.len);
    for (access_list, 0..) |entry, i| {
        entries[i] = .{ .address = entry.address, .storage_keys = entry.storage_keys };
    }
    return entries;
}

fn buildSimulatedTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    request: TransactionRequest,
    block_ctx: guillotine_mini.BlockContext,
    gas: u64,
    options: SimulateOptions,
    nonce_tracker: *std.ArrayList(SimulatedNonceState),
) !SimulatedTransaction {
    const from = request.from orelse primitives.Address.ZERO_ADDRESS;
    const nonce = try nextSimulatedNonce(rt, nonce_tracker, from, request.nonce, options.validation);
    const tx_type = request.tx_type orelse inferredSimulatedTxType(request);
    const chain_id = if (tx_type == 0) request.chain_id else request.chain_id orelse rt.chain_id;
    const max_fee = request.max_fee_per_gas orelse request.gas_price orelse 0;
    const max_priority = request.max_priority_fee_per_gas orelse 0;
    const gas_price = if (tx_type == 0 or tx_type == 1)
        request.gas_price orelse max_fee
    else
        @min(max_fee, block_ctx.block_base_fee +| max_priority);

    const access_list = try cloneTransactionAccessList(allocator, request.access_list);
    errdefer freeTransactionAccessList(allocator, access_list);
    const blob_hashes = try allocator.dupe([32]u8, request.blob_versioned_hashes);
    errdefer allocator.free(blob_hashes);
    const input = try allocator.dupe(u8, request.data);
    errdefer allocator.free(input);

    const raw = try encodeSimulatedTransactionEnvelope(
        allocator,
        tx_type,
        chain_id,
        nonce,
        gas_price,
        max_priority,
        max_fee,
        gas,
        request.to,
        request.value,
        request.data,
        access_list,
        request.max_fee_per_blob_gas orelse 0,
        blob_hashes,
    );
    errdefer allocator.free(raw);

    return .{
        .raw = raw,
        .hash = tx_encoding.transactionHash(raw),
        .from = from,
        .to = request.to,
        .nonce = nonce,
        .gas = gas,
        .value = request.value,
        .input = input,
        .tx_type = tx_type,
        .chain_id = if (tx_type == 0) request.chain_id else chain_id,
        .gas_price = gas_price,
        .max_fee_per_gas = if (tx_type == 2 or tx_type == 3 or tx_type == 4) max_fee else null,
        .max_priority_fee_per_gas = if (tx_type == 2 or tx_type == 3 or tx_type == 4) max_priority else null,
        .max_fee_per_blob_gas = if (tx_type == 3) request.max_fee_per_blob_gas orelse 0 else null,
        .access_list = access_list,
        .blob_versioned_hashes = blob_hashes,
    };
}

fn nextSimulatedNonce(
    rt: *runtime.NodeRuntime,
    nonce_tracker: *std.ArrayList(SimulatedNonceState),
    from: primitives.Address,
    requested_nonce: ?u64,
    validation: bool,
) !u64 {
    for (nonce_tracker.items) |*entry| {
        if (std.mem.eql(u8, entry.address.bytes[0..], from.bytes[0..])) {
            return consumeSimulatedNonce(entry, requested_nonce, validation);
        }
    }

    const state_nonce = rt.state.getNonce(from) catch 0;
    try nonce_tracker.append(rt.allocator, .{
        .address = from,
        .next_nonce = state_nonce,
    });
    return consumeSimulatedNonce(&nonce_tracker.items[nonce_tracker.items.len - 1], requested_nonce, validation);
}

fn consumeSimulatedNonce(
    entry: *SimulatedNonceState,
    requested_nonce: ?u64,
    validation: bool,
) !u64 {
    const nonce = requested_nonce orelse entry.next_nonce;
    if (validation and nonce != entry.next_nonce) {
        setSimulationRpcErrorStatic(-32602, "Invalid params");
        return error.SimulationRpcError;
    }
    entry.next_nonce = std.math.add(u64, nonce, 1) catch blk: {
        if (validation) {
            setSimulationRpcErrorStatic(-32603, "nonce has max value");
            return error.SimulationRpcError;
        }
        break :blk 0;
    };
    return nonce;
}

fn inferredSimulatedTxType(request: TransactionRequest) u8 {
    if (request.blob_versioned_hashes.len != 0) return 3;
    return 2;
}

fn cloneTransactionAccessList(
    allocator: std.mem.Allocator,
    access_list: []const primitives.Transaction.AccessListItem,
) ![]primitives.Transaction.AccessListItem {
    const out = try allocator.alloc(primitives.Transaction.AccessListItem, access_list.len);
    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) allocator.free(out[i].storage_keys);
        allocator.free(out);
    }
    for (access_list, 0..) |entry, i| {
        const keys = try allocator.dupe([32]u8, entry.storage_keys);
        out[i] = .{ .address = entry.address, .storage_keys = keys };
        initialized += 1;
    }
    return out;
}

fn freeTransactionAccessList(allocator: std.mem.Allocator, access_list: []const primitives.Transaction.AccessListItem) void {
    for (access_list) |entry| allocator.free(entry.storage_keys);
    allocator.free(access_list);
}

fn encodeSimulatedTransactionEnvelope(
    allocator: std.mem.Allocator,
    tx_type: u8,
    chain_id: ?u64,
    nonce: u64,
    gas_price: u256,
    max_priority_fee_per_gas: u256,
    max_fee_per_gas: u256,
    gas: u64,
    to: ?primitives.Address,
    value: u256,
    data: []const u8,
    access_list: []const primitives.Transaction.AccessListItem,
    max_fee_per_blob_gas: u256,
    blob_hashes: []const [32]u8,
) ![]u8 {
    return switch (tx_type) {
        0 => encodeLegacyEnvelopeUnsigned(allocator, nonce, gas_price, gas, to, value, data, chain_id),
        1 => encodeTypedEnvelope(allocator, 1, &.{
            try primitives.Rlp.encode(allocator, chain_id orelse 0),
            try primitives.Rlp.encode(allocator, nonce),
            try primitives.Rlp.encode(allocator, gas_price),
            try primitives.Rlp.encode(allocator, gas),
            try encodeOptionalAddressForRlp(allocator, to),
            try primitives.Rlp.encode(allocator, value),
            try primitives.Rlp.encodeBytes(allocator, data),
            try primitives.Transaction.encodeAccessList(allocator, access_list),
            try primitives.Rlp.encode(allocator, @as(u8, 0)),
            try primitives.Rlp.encode(allocator, @as(u8, 0)),
            try primitives.Rlp.encode(allocator, @as(u8, 0)),
        }),
        2 => encodeTypedEnvelope(allocator, 2, &.{
            try primitives.Rlp.encode(allocator, chain_id orelse 0),
            try primitives.Rlp.encode(allocator, nonce),
            try primitives.Rlp.encode(allocator, max_priority_fee_per_gas),
            try primitives.Rlp.encode(allocator, max_fee_per_gas),
            try primitives.Rlp.encode(allocator, gas),
            try encodeOptionalAddressForRlp(allocator, to),
            try primitives.Rlp.encode(allocator, value),
            try primitives.Rlp.encodeBytes(allocator, data),
            try primitives.Transaction.encodeAccessList(allocator, access_list),
            try primitives.Rlp.encode(allocator, @as(u8, 0)),
            try primitives.Rlp.encode(allocator, @as(u8, 0)),
            try primitives.Rlp.encode(allocator, @as(u8, 0)),
        }),
        3 => encodeTypedEnvelope(allocator, 3, &.{
            try primitives.Rlp.encode(allocator, chain_id orelse 0),
            try primitives.Rlp.encode(allocator, nonce),
            try primitives.Rlp.encode(allocator, max_priority_fee_per_gas),
            try primitives.Rlp.encode(allocator, max_fee_per_gas),
            try primitives.Rlp.encode(allocator, gas),
            try encodeRequiredAddressForRlp(allocator, to),
            try primitives.Rlp.encode(allocator, value),
            try primitives.Rlp.encodeBytes(allocator, data),
            try primitives.Transaction.encodeAccessList(allocator, access_list),
            try primitives.Rlp.encode(allocator, max_fee_per_blob_gas),
            try encodeHashListForRlp(allocator, blob_hashes),
            try primitives.Rlp.encode(allocator, @as(u8, 0)),
            try primitives.Rlp.encode(allocator, @as(u8, 0)),
            try primitives.Rlp.encode(allocator, @as(u8, 0)),
        }),
        else => error.InvalidParams,
    };
}

fn encodeLegacyEnvelopeUnsigned(
    allocator: std.mem.Allocator,
    nonce: u64,
    gas_price: u256,
    gas: u64,
    to: ?primitives.Address,
    value: u256,
    data: []const u8,
    chain_id: ?u64,
) ![]u8 {
    const v: u64 = if (chain_id) |id| id * 2 + 35 else 27;
    return encodeRlpListOwned(allocator, &.{
        try primitives.Rlp.encode(allocator, nonce),
        try primitives.Rlp.encode(allocator, gas_price),
        try primitives.Rlp.encode(allocator, gas),
        try encodeOptionalAddressForRlp(allocator, to),
        try primitives.Rlp.encode(allocator, value),
        try primitives.Rlp.encodeBytes(allocator, data),
        try primitives.Rlp.encode(allocator, v),
        try primitives.Rlp.encode(allocator, @as(u8, 0)),
        try primitives.Rlp.encode(allocator, @as(u8, 0)),
    });
}

fn encodeTypedEnvelope(allocator: std.mem.Allocator, tx_type: u8, fields: []const []u8) ![]u8 {
    const payload = try encodeRlpListOwned(allocator, fields);
    defer allocator.free(payload);
    const out = try allocator.alloc(u8, payload.len + 1);
    out[0] = tx_type;
    @memcpy(out[1..], payload);
    return out;
}

fn encodeRlpListOwned(allocator: std.mem.Allocator, fields: []const []u8) ![]u8 {
    defer {
        for (fields) |field| allocator.free(field);
    }
    var total_len: usize = 0;
    for (fields) |field| total_len = try std.math.add(usize, total_len, field.len);

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    if (total_len < 56) {
        try out.append(allocator, 0xc0 + @as(u8, @intCast(total_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, total_len);
        defer allocator.free(len_bytes);
        try out.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try out.appendSlice(allocator, len_bytes);
    }
    for (fields) |field| try out.appendSlice(allocator, field);
    return out.toOwnedSlice(allocator);
}

fn encodeOptionalAddressForRlp(allocator: std.mem.Allocator, to: ?primitives.Address) ![]u8 {
    return if (to) |address| primitives.Rlp.encodeBytes(allocator, &address.bytes) else primitives.Rlp.encodeBytes(allocator, &.{});
}

fn encodeRequiredAddressForRlp(allocator: std.mem.Allocator, to: ?primitives.Address) ![]u8 {
    const address = to orelse return error.InvalidParams;
    return primitives.Rlp.encodeBytes(allocator, &address.bytes);
}

fn encodeHashListForRlp(allocator: std.mem.Allocator, hashes: []const [32]u8) ![]u8 {
    const fields = try allocator.alloc([]u8, hashes.len);
    defer allocator.free(fields);
    for (hashes, 0..) |hash, i| fields[i] = try primitives.Rlp.encodeBytes(allocator, &hash);
    return encodeRlpListOwned(allocator, fields);
}

fn estimateGas(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    tx: TransactionRequest,
    block_ctx: guillotine_mini.BlockContext,
) !u64 {
    const intrinsic = intrinsicGas(rt, tx, block_ctx);
    var high = gasLimit(tx, block_ctx);
    if (high < intrinsic or high > block_ctx.block_gas_limit) return error.ExecutionFailed;

    var high_result = try executeOnce(allocator, rt, tx, block_ctx, high);
    high_result.deinit(allocator);

    var low = intrinsic;
    while (low < high) {
        const mid = low + (high - low) / 2;
        var attempt = executeOnce(allocator, rt, tx, block_ctx, mid) catch |err| switch (err) {
            error.ExecutionFailed => {
                low = mid + 1;
                continue;
            },
            else => return err,
        };
        attempt.deinit(allocator);
        high = mid;
    }

    return high;
}

fn executeOnce(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    tx: TransactionRequest,
    block_ctx: guillotine_mini.BlockContext,
    gas_limit: u64,
) !ExecutionResult {
    return executeOnceWithOptions(allocator, rt, tx, block_ctx, gas_limit, .{});
}

fn executeOnceWithOptions(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    tx: TransactionRequest,
    block_ctx: guillotine_mini.BlockContext,
    gas_limit: u64,
    options: ExecuteOptions,
) !ExecutionResult {
    clearLastExecutionErrorData();
    const intrinsic = intrinsicGas(rt, tx, block_ctx);
    if (intrinsic > gas_limit or gas_limit > block_ctx.block_gas_limit) return error.ExecutionFailed;
    const execution_gas = gas_limit - intrinsic;

    try rt.state.checkpoint();
    var checkpoint_open = true;
    errdefer if (checkpoint_open) rt.state.revert();

    const caller = tx.from orelse rt.coinbase;
    const current_nonce = rt.state.getNonce(caller) catch return error.ExecutionFailed;
    if (tx.nonce) |nonce| {
        if (current_nonce != nonce) return error.ExecutionFailed;
    }
    if (options.increment_nonce or tx.to == null) {
        if (current_nonce == std.math.maxInt(u64)) return error.ExecutionFailed;
        rt.state.setNonce(caller, current_nonce + 1) catch return error.ExecutionFailed;
    }

    var adapter = host_adapter.HostAdapter{ .state = &rt.state };
    const host = adapter.hostInterface();
    var execution_block_ctx = block_ctx;
    if (!tx.has_fee_fields) execution_block_ctx.block_base_fee = 0;

    const EvmType = guillotine_mini.Evm(.{});
    var evm: EvmType = undefined;
    evm.init(
        allocator,
        host,
        rt.hardforkForBlockContext(execution_block_ctx),
        execution_block_ctx,
        caller,
        tx.gas_price orelse 0,
        null,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ExecutionFailed,
    };
    defer evm.deinit();

    var result: ExecutionResult = if (tx.to) |to|
        try executeCall(allocator, &evm, &adapter, caller, to, tx, execution_gas, intrinsic)
    else blk: {
        break :blk try executeCreate(allocator, &evm, &adapter, tx, execution_gas, intrinsic);
    };
    errdefer result.deinit(allocator);

    if (options.persist_state) {
        rt.state.commit();
    } else {
        rt.state.revert();
    }
    checkpoint_open = false;
    return result;
}

fn executeCall(
    allocator: std.mem.Allocator,
    evm: anytype,
    adapter: *host_adapter.HostAdapter,
    caller: primitives.Address,
    to: primitives.Address,
    tx: TransactionRequest,
    execution_gas: u64,
    intrinsic: u64,
) !ExecutionResult {
    const EvmPtr = @TypeOf(evm);
    const EvmType = std.meta.Child(EvmPtr);
    const call_params = EvmType.CallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = tx.value,
        .input = tx.data,
        .gas = execution_gas,
    } };

    var owned = evm.call(call_params).toOwnedResult(allocator) catch return error.OutOfMemory;
    defer owned.deinit(allocator);

    if (adapter.takeHostError() != null) return error.ExecutionFailed;
    if (!owned.success) {
        recordExecutionErrorData(owned.output);
        return error.ExecutionFailed;
    }

    const gas_consumed = if (owned.gas_left > execution_gas) 0 else execution_gas - owned.gas_left;
    return .{
        .output = try allocator.dupe(u8, owned.output),
        .gas_used = intrinsic + gas_consumed,
    };
}

fn executeCreate(
    allocator: std.mem.Allocator,
    evm: anytype,
    adapter: *host_adapter.HostAdapter,
    tx: TransactionRequest,
    execution_gas: u64,
    intrinsic: u64,
) !ExecutionResult {
    try evm.initTransactionState(null);

    const result = evm.inner_create(tx.value, tx.data, execution_gas, null) catch return error.ExecutionFailed;
    if (adapter.takeHostError() != null) return error.ExecutionFailed;
    if (!result.success) {
        recordExecutionErrorData(result.output);
        return error.ExecutionFailed;
    }

    const gas_consumed = if (result.gas_left > execution_gas) 0 else execution_gas - result.gas_left;
    return .{
        .output = try allocator.dupe(u8, result.output),
        .gas_used = intrinsic + gas_consumed,
    };
}

fn recordExecutionErrorData(data: []const u8) void {
    const needed = 2 + data.len * 2;
    if (needed > last_execution_error_data_buf.len) {
        last_execution_error_data = null;
        return;
    }
    last_execution_error_data_buf[0] = '0';
    last_execution_error_data_buf[1] = 'x';
    writeHexLower(last_execution_error_data_buf[2..needed], data);
    last_execution_error_data = last_execution_error_data_buf[0..needed];
}

fn gasLimit(tx: TransactionRequest, block_ctx: guillotine_mini.BlockContext) u64 {
    return tx.gas orelse block_ctx.block_gas_limit;
}

fn intrinsicGas(rt: *const runtime.NodeRuntime, tx: TransactionRequest, block_ctx: guillotine_mini.BlockContext) u64 {
    var gas = tx_processor.intrinsicGasForFork(tx.data, tx.to == null, rt.hardforkForBlockContext(block_ctx));
    if (rt.hardforkForBlockContext(block_ctx).isAtLeast(.BERLIN)) {
        gas +|= tx.access_list_addresses *| @as(u64, 2400);
        gas +|= tx.access_list_storage_keys *| @as(u64, 1900);
    }
    return gas;
}

fn blockContext(
    rt: *runtime.NodeRuntime,
    block_number: u64,
    recent_block_hashes: *[256][32]u8,
) !guillotine_mini.BlockContext {
    const block = (try rt.blockchain.getBlockByNumber(block_number)) orelse {
        if (block_number != rt.head_block_number) return error.InvalidParams;
        const ctx = guillotine_mini.BlockContext{
            .chain_id = rt.chain_id,
            .block_number = rt.head_block_number,
            .block_timestamp = rt.head_block_timestamp,
            .block_difficulty = 0,
            .block_prevrandao = 0,
            .block_coinbase = rt.coinbase,
            .block_gas_limit = rt.dev_runtime.config.block_gas_limit,
            .block_base_fee = rt.base_fee,
            .blob_base_fee = rt.blob_base_fee,
        };
        var effective = block_builder.blockContextWithEnvironmentOverrides(&rt.dev_runtime, ctx);
        effective.block_hashes = try rt.recentBlockHashesForExecution(effective.block_number, recent_block_hashes);
        return effective;
    };

    const ctx = guillotine_mini.BlockContext{
        .chain_id = rt.chain_id,
        .block_number = block.header.number,
        .block_timestamp = block.header.timestamp,
        .block_difficulty = block.header.difficulty,
        .block_prevrandao = std.mem.readInt(u256, &block.header.mix_hash, .big),
        .block_coinbase = block.header.beneficiary,
        .block_gas_limit = block.header.gas_limit,
        .block_base_fee = block.header.base_fee_per_gas orelse 0,
        .blob_base_fee = rt.blob_base_fee,
    };
    var effective = block_builder.blockContextWithEnvironmentOverrides(&rt.dev_runtime, ctx);
    effective.block_hashes = try rt.recentBlockHashesForExecution(effective.block_number, recent_block_hashes);
    return effective;
}

fn parseAddressValue(value: std.json.Value) !primitives.Address {
    return rpc_parse.parseAddressValue(value);
}

fn parseAddressString(text: []const u8) !primitives.Address {
    return rpc_parse.parseAddressString(text);
}

fn parseQuantityU64Value(value: std.json.Value) !u64 {
    return rpc_parse.parseQuantityValue(u64, value);
}

fn parseQuantityU64String(text: []const u8) !u64 {
    return rpc_parse.parseQuantityString(u64, text);
}

fn parseQuantityU256Value(value: std.json.Value) !u256 {
    return rpc_parse.parseQuantityValue(u256, value);
}

fn parsePrevRandaoValue(value: std.json.Value) !u256 {
    if (parseQuantityU256Value(value)) |quantity| return quantity else |_| {}
    const hash = try rpc_parse.parseHash32Value(value);
    return std.mem.readInt(u256, &hash, .big);
}

fn parseQuantityU256String(text: []const u8) !u256 {
    return rpc_parse.parseQuantityString(u256, text);
}

fn parseHexDataValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return rpc_parse.parseHexDataBytes(allocator, value);
}

fn parseBytes32U256(text: []const u8) !u256 {
    _ = try rpc_parse.parseHash32String(text);
    return std.fmt.parseInt(u256, text[2..], 16) catch return error.InvalidParams;
}

fn hasHexPrefix(text: []const u8) bool {
    return rpc_parse.hasHexPrefix(text);
}

fn isQuantityHex(text: []const u8) bool {
    return rpc_parse.isQuantityHex(text);
}

fn hexQuantity(allocator: std.mem.Allocator, value: u64) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{value}) };
}

fn hexBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    if (bytes.len == 0) {
        return .{ .string = try allocator.dupe(u8, "0x") };
    }

    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    writeHexLower(out[2..], bytes);
    return .{ .string = out };
}

fn simulateCallValueFromReceipt(
    allocator: std.mem.Allocator,
    receipt: primitives.Receipt.Receipt,
    output: []const u8,
    tx: SimulatedTransaction,
    transfers: []const SimulatedTransfer,
    options: SimulateOptions,
    block_timestamp: u64,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &cleanup);
    }
    const success = if (receipt.status) |status| status.success else true;
    try putOwnedJsonValue(&obj, allocator, "returnData", try hexBytes(allocator, if (success) output else &.{}));
    try putOwnedJsonValue(&obj, allocator, "logs", try simulateLogsValue(allocator, receipt, tx, transfers, options, block_timestamp));
    try putOwnedJsonValue(&obj, allocator, "gasUsed", try hexQuantityU256(allocator, receipt.gas_used));
    try putOwnedJsonValue(&obj, allocator, "maxUsedGas", try hexQuantityU256(allocator, receipt.gas_used));
    try putOwnedJsonValue(&obj, allocator, "status", .{ .string = try allocator.dupe(u8, if (success) "0x1" else "0x0") });
    if (!success) {
        var err_obj = std.json.ObjectMap.init(allocator);
        errdefer {
            var cleanup = std.json.Value{ .object = err_obj };
            deinitJsonValue(allocator, &cleanup);
        }
        const out_of_gas = output.len == 0 and receipt.gas_used >= tx.gas;
        if (out_of_gas) {
            try putOwnedJsonValue(&err_obj, allocator, "message", .{ .string = try allocator.dupe(u8, "out of gas") });
            try putOwnedJsonValue(&err_obj, allocator, "code", .{ .integer = -32015 });
        } else {
            try putOwnedJsonValue(&err_obj, allocator, "message", .{ .string = try revertErrorMessage(allocator, output) });
            try putOwnedJsonValue(&err_obj, allocator, "code", .{ .integer = 3 });
            try putOwnedJsonValue(&err_obj, allocator, "data", try hexBytes(allocator, output));
        }
        try putOwnedJsonValue(&obj, allocator, "error", .{ .object = err_obj });
    }
    return .{ .object = obj };
}

fn revertErrorMessage(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
    if (decodeRevertReason(output)) |reason| {
        return std.fmt.allocPrint(allocator, "execution reverted: {s}", .{reason});
    }
    return allocator.dupe(u8, "execution reverted");
}

fn decodeRevertReason(output: []const u8) ?[]const u8 {
    const error_string_selector = [_]u8{ 0x08, 0xc3, 0x79, 0xa0 };
    if (output.len < 4 + 32 + 32) return null;
    if (!std.mem.eql(u8, output[0..4], &error_string_selector)) return null;
    const offset = readAbiWord(output, 4) orelse return null;
    if (offset > std.math.maxInt(usize)) return null;
    const len_pos = 4 + @as(usize, @intCast(offset));
    const reason_len_u256 = readAbiWord(output, len_pos) orelse return null;
    if (reason_len_u256 > std.math.maxInt(usize)) return null;
    const reason_len: usize = @intCast(reason_len_u256);
    const reason_start = len_pos + 32;
    if (reason_start + reason_len > output.len) return null;
    return output[reason_start .. reason_start + reason_len];
}

fn readAbiWord(output: []const u8, start: usize) ?u256 {
    if (start > output.len or output.len - start < 32) return null;
    return std.mem.readInt(u256, output[start..][0..32], .big);
}

const PendingBalanceDelta = struct {
    address: primitives.Address,
    amount: u256,
    debit: bool,
};

fn simulatedTransfersFromBalanceChanges(
    allocator: std.mem.Allocator,
    changes: []const host_adapter.HostAdapter.BalanceChange,
) ![]SimulatedTransfer {
    var transfers = std.ArrayList(SimulatedTransfer){};
    errdefer transfers.deinit(allocator);

    var pending: ?PendingBalanceDelta = null;
    for (changes) |change| {
        if (change.before == change.after) continue;
        const delta = if (change.before > change.after)
            PendingBalanceDelta{
                .address = change.address,
                .amount = change.before - change.after,
                .debit = true,
            }
        else
            PendingBalanceDelta{
                .address = change.address,
                .amount = change.after - change.before,
                .debit = false,
            };
        if (delta.amount == 0) continue;

        if (pending) |prior| {
            if (prior.amount == delta.amount and prior.debit != delta.debit) {
                if (prior.debit) {
                    try transfers.append(allocator, .{
                        .from = prior.address,
                        .to = delta.address,
                        .value = delta.amount,
                    });
                } else {
                    try transfers.append(allocator, .{
                        .from = delta.address,
                        .to = prior.address,
                        .value = delta.amount,
                    });
                }
                pending = null;
                continue;
            }
        }

        if (pending) |prior| {
            if (prior.debit) {
                try transfers.append(allocator, .{
                    .from = prior.address,
                    .to = primitives.Address.ZERO_ADDRESS,
                    .value = prior.amount,
                });
            }
        }
        pending = delta;
    }

    if (pending) |prior| {
        if (prior.debit) {
            try transfers.append(allocator, .{
                .from = prior.address,
                .to = primitives.Address.ZERO_ADDRESS,
                .value = prior.amount,
            });
        }
    }

    return transfers.toOwnedSlice(allocator);
}

fn simulateLogsValue(
    allocator: std.mem.Allocator,
    receipt: primitives.Receipt.Receipt,
    tx: SimulatedTransaction,
    transfers: []const SimulatedTransfer,
    options: SimulateOptions,
    block_timestamp: u64,
) !std.json.Value {
    var array = switch (try logsValue(allocator, receipt.logs, receipt.block_hash, block_timestamp)) {
        .array => |array| array,
        else => unreachable,
    };
    errdefer {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    }

    const success = if (receipt.status) |status| status.success else true;
    if (options.trace_transfers and success) {
        for (transfers) |transfer| {
            if (transfer.value == 0) continue;
            const synthetic_log_index = receipt.transaction_index + @as(u32, @intCast(array.items.len));
            try array.append(try traceTransferLogValue(
                allocator,
                transfer.from,
                transfer.to,
                transfer.value,
                receipt.block_hash,
                receipt.block_number,
                block_timestamp,
                receipt.transaction_hash,
                receipt.transaction_index,
                synthetic_log_index,
            ));
        }
    }
    if (options.trace_transfers and success and transfers.len == 0 and tx.value > 0) {
        if (tx.to) |to| {
            const synthetic_log_index = receipt.transaction_index + @as(u32, @intCast(array.items.len));
            try array.append(try traceTransferLogValue(
                allocator,
                tx.from,
                to,
                tx.value,
                receipt.block_hash,
                receipt.block_number,
                block_timestamp,
                receipt.transaction_hash,
                receipt.transaction_index,
                synthetic_log_index,
            ));
        }
    }

    return .{ .array = array };
}

fn traceTransferLogValue(
    allocator: std.mem.Allocator,
    from: primitives.Address,
    to: primitives.Address,
    value: u256,
    block_hash: [32]u8,
    block_number: u64,
    block_timestamp: u64,
    transaction_hash: [32]u8,
    transaction_index: u32,
    log_index: u32,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &cleanup);
    }

    const eth_transfer_address = primitives.Address{ .bytes = [_]u8{0xee} ** 20 };
    var topics = [_][32]u8{
        [_]u8{ 0xdd, 0xf2, 0x52, 0xad, 0x1b, 0xe2, 0xc8, 0x9b, 0x69, 0xc2, 0xb0, 0x68, 0xfc, 0x37, 0x8d, 0xaa, 0x95, 0x2b, 0xa7, 0xf1, 0x63, 0xc4, 0xa1, 0x16, 0x28, 0xf5, 0x5a, 0x4d, 0xf5, 0x23, 0xb3, 0xef },
        paddedAddressTopic(from),
        paddedAddressTopic(to),
    };
    var data: [32]u8 = undefined;
    std.mem.writeInt(u256, &data, value, .big);

    try putOwnedJsonValue(&obj, allocator, "address", try addressValue(allocator, eth_transfer_address));
    try putOwnedJsonValue(&obj, allocator, "blockHash", try hashValue(allocator, block_hash));
    try putOwnedJsonValue(&obj, allocator, "blockNumber", try hexQuantity(allocator, block_number));
    try putOwnedJsonValue(&obj, allocator, "blockTimestamp", try hexQuantity(allocator, block_timestamp));
    try putOwnedJsonValue(&obj, allocator, "data", try fixedBytesValue(allocator, &data));
    try putOwnedJsonValue(&obj, allocator, "logIndex", try hexQuantity(allocator, log_index));
    try putOwnedJsonValue(&obj, allocator, "removed", .{ .bool = false });
    try putOwnedJsonValue(&obj, allocator, "topics", try hashArrayJsonValue(allocator, &topics));
    try putOwnedJsonValue(&obj, allocator, "transactionHash", try hashValue(allocator, transaction_hash));
    try putOwnedJsonValue(&obj, allocator, "transactionIndex", try hexQuantity(allocator, transaction_index));
    return .{ .object = obj };
}

fn paddedAddressTopic(address: primitives.Address) [32]u8 {
    var out = [_]u8{0} ** 32;
    @memcpy(out[12..], &address.bytes);
    return out;
}

fn simulatedBlockValue(
    allocator: std.mem.Allocator,
    block: SimulatedBlockData,
    calls: std.json.Array,
    transactions: []const SimulatedTransaction,
    return_full_transactions: bool,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &cleanup);
    }

    const zero_nonce = [_]u8{0} ** 8;
    const zero_hash = [_]u8{0} ** 32;

    try putOwnedJsonValue(&obj, allocator, "hash", try hashValue(allocator, block.block_hash));
    try putOwnedJsonValue(&obj, allocator, "parentHash", try hashValue(allocator, block.parent_hash));
    try putOwnedJsonValue(&obj, allocator, "sha3Uncles", try hashValue(allocator, primitives.BlockHeader.EMPTY_OMMERS_HASH));
    try putOwnedJsonValue(&obj, allocator, "miner", try addressValue(allocator, block.block_ctx.block_coinbase));
    try putOwnedJsonValue(&obj, allocator, "stateRoot", try hashValue(allocator, block.state_root));
    try putOwnedJsonValue(&obj, allocator, "transactionsRoot", try hashValue(allocator, block.transactions_root));
    try putOwnedJsonValue(&obj, allocator, "receiptsRoot", try hashValue(allocator, block.receipts_root));
    try putOwnedJsonValue(&obj, allocator, "logsBloom", try fixedBytesValue(allocator, &block.logs_bloom));
    try putOwnedJsonValue(&obj, allocator, "difficulty", try hexQuantityU256(allocator, block.block_ctx.block_difficulty));
    try putOwnedJsonValue(&obj, allocator, "number", try hexQuantity(allocator, block.block_ctx.block_number));
    if (block.fork.isAtLeast(.CANCUN)) {
        try putOwnedJsonValue(&obj, allocator, "parentBeaconBlockRoot", try hashValue(allocator, zero_hash));
    }
    try putOwnedJsonValue(&obj, allocator, "gasLimit", try hexQuantity(allocator, block.block_ctx.block_gas_limit));
    try putOwnedJsonValue(&obj, allocator, "gasUsed", try hexQuantity(allocator, block.gas_used));
    try putOwnedJsonValue(&obj, allocator, "timestamp", try hexQuantity(allocator, block.block_ctx.block_timestamp));
    try putOwnedJsonValue(&obj, allocator, "extraData", .{ .string = try allocator.dupe(u8, "0x") });
    try putOwnedJsonValue(&obj, allocator, "mixHash", try hashValue(allocator, intToHash(block.block_ctx.block_prevrandao)));
    try putOwnedJsonValue(&obj, allocator, "nonce", try fixedBytesValue(allocator, &zero_nonce));
    if (block.fork.isAtLeast(.LONDON)) {
        try putOwnedJsonValue(&obj, allocator, "baseFeePerGas", try hexQuantityU256(allocator, block.block_ctx.block_base_fee));
    }
    if (block.fork.isAtLeast(.CANCUN)) {
        try putOwnedJsonValue(&obj, allocator, "blobGasUsed", try hexQuantity(allocator, block.blob_gas_used));
        try putOwnedJsonValue(&obj, allocator, "excessBlobGas", .{ .string = try allocator.dupe(u8, "0x0") });
    }
    if (block.requests_hash) |requests_hash| try putOwnedJsonValue(&obj, allocator, "requestsHash", try hashValue(allocator, requests_hash));
    try putOwnedJsonValue(&obj, allocator, "size", try hexQuantity(allocator, block.size));
    try putOwnedJsonValue(&obj, allocator, "transactions", try simulatedTransactionsValue(allocator, transactions, block, return_full_transactions));
    try putOwnedJsonValue(&obj, allocator, "uncles", .{ .array = std.json.Array.init(allocator) });
    if (block.fork.isAtLeast(.SHANGHAI)) {
        try putOwnedJsonValue(&obj, allocator, "withdrawals", .{ .array = std.json.Array.init(allocator) });
        try putOwnedJsonValue(&obj, allocator, "withdrawalsRoot", try hashValue(allocator, primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT));
    }
    try putOwnedJsonValue(&obj, allocator, "calls", .{ .array = calls });
    return .{ .object = obj };
}

fn simulatedTransactionsValue(
    allocator: std.mem.Allocator,
    transactions: []const SimulatedTransaction,
    block: SimulatedBlockData,
    return_full_transactions: bool,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    }
    for (transactions, 0..) |tx, i| {
        if (return_full_transactions) {
            try array.append(try simulatedTransactionValue(allocator, tx, block, @intCast(i)));
        } else {
            try array.append(try hashValue(allocator, tx.hash));
        }
    }
    return .{ .array = array };
}

fn simulatedTransactionValue(
    allocator: std.mem.Allocator,
    tx: SimulatedTransaction,
    block: SimulatedBlockData,
    transaction_index: u32,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &cleanup);
    }
    try putOwnedJsonValue(&obj, allocator, "blockHash", try hashValue(allocator, block.block_hash));
    try putOwnedJsonValue(&obj, allocator, "blockNumber", try hexQuantity(allocator, block.block_ctx.block_number));
    try putOwnedJsonValue(&obj, allocator, "blockTimestamp", try hexQuantity(allocator, block.block_ctx.block_timestamp));
    try putOwnedJsonValue(&obj, allocator, "from", try addressValue(allocator, tx.from));
    try putOwnedJsonValue(&obj, allocator, "gas", try hexQuantity(allocator, tx.gas));
    if (tx.gas_price) |gas_price| try putOwnedJsonValue(&obj, allocator, "gasPrice", try hexQuantityU256(allocator, gas_price));
    if (tx.max_fee_per_gas) |max_fee| try putOwnedJsonValue(&obj, allocator, "maxFeePerGas", try hexQuantityU256(allocator, max_fee));
    if (tx.max_priority_fee_per_gas) |tip| try putOwnedJsonValue(&obj, allocator, "maxPriorityFeePerGas", try hexQuantityU256(allocator, tip));
    if (tx.max_fee_per_blob_gas) |max_blob_fee| try putOwnedJsonValue(&obj, allocator, "maxFeePerBlobGas", try hexQuantityU256(allocator, max_blob_fee));
    try putOwnedJsonValue(&obj, allocator, "hash", try hashValue(allocator, tx.hash));
    try putOwnedJsonValue(&obj, allocator, "input", try hexBytes(allocator, tx.input));
    try putOwnedJsonValue(&obj, allocator, "nonce", try hexQuantity(allocator, tx.nonce));
    try putOwnedJsonValue(&obj, allocator, "to", if (tx.to) |to| try addressValue(allocator, to) else .null);
    try putOwnedJsonValue(&obj, allocator, "transactionIndex", try hexQuantity(allocator, transaction_index));
    try putOwnedJsonValue(&obj, allocator, "value", try hexQuantityU256(allocator, tx.value));
    try putOwnedJsonValue(&obj, allocator, "type", try hexQuantity(allocator, tx.tx_type));
    try putOwnedJsonValue(&obj, allocator, "accessList", try accessListJsonValue(allocator, tx.access_list));
    if (tx.chain_id) |chain_id| try putOwnedJsonValue(&obj, allocator, "chainId", try hexQuantity(allocator, chain_id));
    if (tx.blob_versioned_hashes.len != 0) try putOwnedJsonValue(&obj, allocator, "blobVersionedHashes", try hashArrayJsonValue(allocator, tx.blob_versioned_hashes));
    try putOwnedJsonValue(&obj, allocator, "v", .{ .string = try allocator.dupe(u8, "0x0") });
    try putOwnedJsonValue(&obj, allocator, "r", .{ .string = try allocator.dupe(u8, "0x0") });
    try putOwnedJsonValue(&obj, allocator, "s", .{ .string = try allocator.dupe(u8, "0x0") });
    if (tx.tx_type != 0) try putOwnedJsonValue(&obj, allocator, "yParity", .{ .string = try allocator.dupe(u8, "0x0") });
    return .{ .object = obj };
}

fn logsValue(
    allocator: std.mem.Allocator,
    logs: []const primitives.EventLog.EventLog,
    block_hash: [32]u8,
    block_timestamp: u64,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    }
    for (logs) |event_log| {
        var obj = std.json.ObjectMap.init(allocator);
        errdefer {
            var cleanup = std.json.Value{ .object = obj };
            deinitJsonValue(allocator, &cleanup);
        }
        try putOwnedJsonValue(&obj, allocator, "address", try addressValue(allocator, event_log.address));
        try putOwnedJsonValue(&obj, allocator, "topics", try hashArrayJsonValue(allocator, event_log.topics));
        try putOwnedJsonValue(&obj, allocator, "data", try hexBytes(allocator, event_log.data));
        try putOwnedJsonValue(&obj, allocator, "blockNumber", try hexQuantity(allocator, event_log.block_number orelse 0));
        try putOwnedJsonValue(&obj, allocator, "transactionHash", try hashValue(allocator, event_log.transaction_hash orelse primitives.Hash.ZERO));
        try putOwnedJsonValue(&obj, allocator, "transactionIndex", try hexQuantity(allocator, event_log.transaction_index orelse 0));
        try putOwnedJsonValue(&obj, allocator, "blockHash", try hashValue(allocator, block_hash));
        try putOwnedJsonValue(&obj, allocator, "blockTimestamp", try hexQuantity(allocator, block_timestamp));
        try putOwnedJsonValue(&obj, allocator, "logIndex", try hexQuantity(allocator, event_log.log_index orelse 0));
        try putOwnedJsonValue(&obj, allocator, "removed", .{ .bool = event_log.removed });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn hashArrayJsonValue(allocator: std.mem.Allocator, hashes: []const [32]u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    }
    for (hashes) |hash| try array.append(try hashValue(allocator, hash));
    return .{ .array = array };
}

fn accessListJsonValue(
    allocator: std.mem.Allocator,
    access_list: []const primitives.Transaction.AccessListItem,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    }
    for (access_list) |entry| {
        var obj = std.json.ObjectMap.init(allocator);
        errdefer {
            var cleanup = std.json.Value{ .object = obj };
            deinitJsonValue(allocator, &cleanup);
        }
        try putOwnedJsonValue(&obj, allocator, "address", try addressValue(allocator, entry.address));
        try putOwnedJsonValue(&obj, allocator, "storageKeys", try hashArrayJsonValue(allocator, entry.storage_keys));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn simulatedHeader(
    block_ctx: guillotine_mini.BlockContext,
    parent_hash: [32]u8,
    state_root: [32]u8,
    transactions_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    gas_used: u64,
    blob_gas_used: u64,
    fork: guillotine_mini.Hardfork,
) primitives.BlockHeader.BlockHeader {
    return .{
        .parent_hash = parent_hash,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .beneficiary = block_ctx.block_coinbase,
        .state_root = state_root,
        .transactions_root = transactions_root,
        .receipts_root = receipts_root,
        .logs_bloom = logs_bloom,
        .difficulty = block_ctx.block_difficulty,
        .number = block_ctx.block_number,
        .gas_limit = block_ctx.block_gas_limit,
        .gas_used = gas_used,
        .timestamp = block_ctx.block_timestamp,
        .extra_data = &.{},
        .mix_hash = intToHash(block_ctx.block_prevrandao),
        .nonce = [_]u8{0} ** 8,
        .base_fee_per_gas = if (fork.isAtLeast(.LONDON)) block_ctx.block_base_fee else null,
        .withdrawals_root = if (fork.isAtLeast(.SHANGHAI)) primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT else null,
        .blob_gas_used = if (fork.isAtLeast(.CANCUN)) blob_gas_used else null,
        .excess_blob_gas = if (fork.isAtLeast(.CANCUN)) 0 else null,
        .parent_beacon_block_root = if (fork.isAtLeast(.CANCUN)) primitives.Hash.ZERO else null,
    };
}

fn headerFromSimulatedBlock(block: SimulatedBlockData) primitives.BlockHeader.BlockHeader {
    return simulatedHeader(
        block.block_ctx,
        block.parent_hash,
        block.state_root,
        block.transactions_root,
        block.receipts_root,
        block.logs_bloom,
        block.gas_used,
        block.blob_gas_used,
        block.fork,
    );
}

fn simBlockBuilderFork(fork: guillotine_mini.Hardfork) block_builder.Hardfork {
    if (fork.isAtLeast(.PRAGUE)) return .prague;
    if (fork.isAtLeast(.CANCUN)) return .cancun;
    if (fork.isAtLeast(.SHANGHAI)) return .shanghai;
    if (fork.isAtLeast(.MERGE)) return .paris;
    if (fork.isAtLeast(.LONDON)) return .london;
    if (fork.isAtLeast(.BERLIN)) return .berlin;
    if (fork.isAtLeast(.ISTANBUL)) return .istanbul;
    if (fork.isAtLeast(.CONSTANTINOPLE)) return .constantinople;
    if (fork.isAtLeast(.BYZANTIUM)) return .byzantium;
    if (fork.isAtLeast(.HOMESTEAD)) return .homestead;
    return .frontier;
}

fn simulatedBlockSize(
    allocator: std.mem.Allocator,
    header: primitives.BlockHeader.BlockHeader,
    requests_hash: ?[32]u8,
    raw_txs: []const primitives.BlockBody.TransactionData,
    fork: guillotine_mini.Hardfork,
) !u64 {
    const header_encoded = try encodeHeaderForSimulatedBlock(allocator, header, requests_hash);
    defer allocator.free(header_encoded);
    const txs_encoded = try encodeTransactionsListForBlock(allocator, raw_txs);
    defer allocator.free(txs_encoded);
    const ommers_encoded = try encodeRlpListNoFree(allocator, &.{});
    defer allocator.free(ommers_encoded);
    const outer = if (fork.isAtLeast(.SHANGHAI)) blk: {
        const withdrawals_encoded = try encodeRlpListNoFree(allocator, &.{});
        defer allocator.free(withdrawals_encoded);
        break :blk try encodeRlpListNoFree(allocator, &.{ header_encoded, txs_encoded, ommers_encoded, withdrawals_encoded });
    } else try encodeRlpListNoFree(allocator, &.{ header_encoded, txs_encoded, ommers_encoded });
    defer allocator.free(outer);
    return @intCast(outer.len);
}

fn encodeHeaderForSimulatedBlock(
    allocator: std.mem.Allocator,
    header: primitives.BlockHeader.BlockHeader,
    requests_hash: ?[32]u8,
) ![]u8 {
    if (requests_hash == null) return primitives.BlockHeader.rlpEncode(&header, allocator);
    return encodeRlpListOwned(allocator, &.{
        try primitives.Rlp.encodeBytes(allocator, &header.parent_hash),
        try primitives.Rlp.encodeBytes(allocator, &header.ommers_hash),
        try primitives.Rlp.encodeBytes(allocator, &header.beneficiary.bytes),
        try primitives.Rlp.encodeBytes(allocator, &header.state_root),
        try primitives.Rlp.encodeBytes(allocator, &header.transactions_root),
        try primitives.Rlp.encodeBytes(allocator, &header.receipts_root),
        try primitives.Rlp.encodeBytes(allocator, &header.logs_bloom),
        try primitives.Rlp.encode(allocator, header.difficulty),
        try primitives.Rlp.encode(allocator, header.number),
        try primitives.Rlp.encode(allocator, header.gas_limit),
        try primitives.Rlp.encode(allocator, header.gas_used),
        try primitives.Rlp.encode(allocator, header.timestamp),
        try primitives.Rlp.encodeBytes(allocator, header.extra_data),
        try primitives.Rlp.encodeBytes(allocator, &header.mix_hash),
        try primitives.Rlp.encodeBytes(allocator, &header.nonce),
        try primitives.Rlp.encode(allocator, header.base_fee_per_gas orelse 0),
        try primitives.Rlp.encodeBytes(allocator, &(header.withdrawals_root orelse primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT)),
        try primitives.Rlp.encode(allocator, header.blob_gas_used orelse 0),
        try primitives.Rlp.encode(allocator, header.excess_blob_gas orelse 0),
        try primitives.Rlp.encodeBytes(allocator, &(header.parent_beacon_block_root orelse primitives.Hash.ZERO)),
        try primitives.Rlp.encodeBytes(allocator, &(requests_hash.?)),
    });
}

fn encodeTransactionsListForBlock(
    allocator: std.mem.Allocator,
    raw_txs: []const primitives.BlockBody.TransactionData,
) ![]u8 {
    const fields = try allocator.alloc([]u8, raw_txs.len);
    defer allocator.free(fields);
    for (raw_txs, 0..) |tx, i| fields[i] = try primitives.Rlp.encodeBytes(allocator, tx.raw);
    return encodeRlpListOwned(allocator, fields);
}

fn encodeRlpListNoFree(allocator: std.mem.Allocator, fields: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (fields) |field| total_len = try std.math.add(usize, total_len, field.len);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    if (total_len < 56) {
        try out.append(allocator, 0xc0 + @as(u8, @intCast(total_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, total_len);
        defer allocator.free(len_bytes);
        try out.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try out.appendSlice(allocator, len_bytes);
    }
    for (fields) |field| try out.appendSlice(allocator, field);
    return out.toOwnedSlice(allocator);
}

fn intToHash(value: u256) [32]u8 {
    var out: [32]u8 = undefined;
    std.mem.writeInt(u256, &out, value, .big);
    return out;
}

fn hashValue(allocator: std.mem.Allocator, hash: [32]u8) !std.json.Value {
    return fixedBytesValue(allocator, &hash);
}

fn addressValue(allocator: std.mem.Allocator, address: primitives.Address) !std.json.Value {
    const out = try allocator.alloc(u8, 42);
    out[0] = '0';
    out[1] = 'x';
    writeHexLower(out[2..], &address.bytes);
    return .{ .string = out };
}

fn checksumAddressString(allocator: std.mem.Allocator, address: primitives.Address) ![]u8 {
    const lower_hex = std.fmt.bytesToHex(address.bytes, .lower);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(lower_hex[0..], &digest, .{});

    const out = try allocator.alloc(u8, 42);
    out[0] = '0';
    out[1] = 'x';
    for (lower_hex, 0..) |char, i| {
        const hash_nibble = if ((i & 1) == 0)
            digest[i / 2] >> 4
        else
            digest[i / 2] & 0x0f;
        out[2 + i] = if (char >= 'a' and char <= 'f' and hash_nibble >= 8)
            char - ('a' - 'A')
        else
            char;
    }
    return out;
}

fn fixedBytesValue(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    writeHexLower(out[2..], bytes);
    return .{ .string = out };
}

fn hexQuantityU256(allocator: std.mem.Allocator, value: u256) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{value}) };
}

fn putOwnedJsonValue(
    obj: *std.json.ObjectMap,
    allocator: std.mem.Allocator,
    key: []const u8,
    value: std.json.Value,
) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(owned_key, value);
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string => |text| allocator.free(text),
        .array => |*array| {
            for (array.items) |*item| deinitJsonValue(allocator, item);
            array.deinit();
        },
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
        else => {},
    }
}

fn writeHexLower(out: []u8, bytes: []const u8) void {
    const charset = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = charset[(byte >> 4) & 0x0f];
        out[i * 2 + 1] = charset[byte & 0x0f];
    }
}
