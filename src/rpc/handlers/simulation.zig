const std = @import("std");
const primitives = @import("primitives");
const guillotine_mini = @import("guillotine_mini");
const runtime = @import("../../node/runtime.zig");
const block_builder = @import("../../block_builder.zig");
const host_adapter = @import("../../host_adapter.zig");
const tx_processor = @import("../../tx_processor.zig");
const rpc_parse = @import("../parse.zig");

pub const MODE_UNSUPPORTED_ERROR_CODE: i32 = -32010;
pub const MODE_UNSUPPORTED_MESSAGE = "mode-unsupported";
const MAX_RPC_ERROR_DATA_HEX_BYTES: usize = 32 * 1024;

threadlocal var last_execution_error_data_buf: [MAX_RPC_ERROR_DATA_HEX_BYTES]u8 = undefined;
threadlocal var last_execution_error_data: ?[]const u8 = null;

const TransactionRequest = struct {
    from: ?primitives.Address = null,
    to: ?primitives.Address = null,
    gas: ?u64 = null,
    gas_price: ?u256 = null,
    has_fee_fields: bool = false,
    value: u256 = 0,
    nonce: ?u64 = null,
    access_list_addresses: u64 = 0,
    access_list_storage_keys: u64 = 0,
    data: []u8,

    fn deinit(self: *TransactionRequest, allocator: std.mem.Allocator) void {
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
        try applyStateOverrides(allocator, rt, overrides);
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
        try applyStateOverrides(allocator, rt, overrides);
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
    try ensureCurrentStateSelector(rt, selected_block_number);

    const block_state_calls = switch (payload.get("blockStateCalls") orelse return error.InvalidParams) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    _ = try optionalBool(payload, "traceTransfers");
    _ = try optionalBool(payload, "validation");
    const return_full_transactions = try optionalBool(payload, "returnFullTransactions") orelse false;

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

    try rt.state.checkpoint();
    defer rt.state.revert();

    var recent_block_hashes: [256][32]u8 = undefined;
    var block_ctx = try blockContext(rt, selected_block_number, &recent_block_hashes);
    block_ctx.block_number +|= 1;
    block_ctx.block_timestamp +|= 1;

    var parent_hash = rt.blockchain.getCanonicalHash(selected_block_number) orelse [_]u8{0} ** 32;
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

        if (block_request.get("blockOverrides")) |overrides| {
            try applyBlockOverrides(&block_ctx, overrides);
        }
        if (block_request.get("stateOverrides")) |overrides| {
            try applyStateOverrides(allocator, rt, overrides);
        }

        const calls = if (block_request.get("calls")) |calls_value|
            try arrayItemsValue(calls_value)
        else
            &[_]std.json.Value{};

        var call_results = std.json.Array.init(allocator);
        errdefer {
            for (call_results.items) |*item| deinitJsonValue(allocator, item);
            call_results.deinit();
        }
        var gas_used: u64 = 0;
        for (calls) |call_value| {
            var tx = try parseTransactionRequest(allocator, call_value);
            defer tx.deinit(allocator);

            var result = executeOnceWithOptions(allocator, rt, tx, block_ctx, gasLimit(tx, block_ctx), .{
                .persist_state = true,
                .increment_nonce = true,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try call_results.append(try failedSimulateCallValue(allocator));
                    continue;
                },
            };
            defer result.deinit(allocator);
            gas_used +|= result.gas_used;
            try call_results.append(try successfulSimulateCallValue(allocator, result));
        }

        const block_hash = simulatedBlockHash(block_ctx.block_number, parent_hash);
        try blocks.append(try simulatedBlockValue(
            allocator,
            rt,
            block_ctx,
            parent_hash,
            block_hash,
            gas_used,
            call_results,
            return_full_transactions,
        ));
        parent_hash = block_hash;
        block_ctx.block_number +|= 1;
        block_ctx.block_timestamp +|= 1;
    }

    return .{ .array = blocks };
}

pub fn takeLastExecutionErrorData() ?[]const u8 {
    const data = last_execution_error_data;
    last_execution_error_data = null;
    return data;
}

fn clearLastExecutionErrorData() void {
    last_execution_error_data = null;
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
            tx.gas_price = try parseQuantityU256Value(field);
            tx.has_fee_fields = true;
        } else if (std.mem.eql(u8, key, "maxPriorityFeePerGas")) {
            _ = try parseQuantityU256Value(field);
            tx.has_fee_fields = true;
        } else if (std.mem.eql(u8, key, "maxFeePerBlobGas")) {
            _ = try parseQuantityU256Value(field);
        } else if (std.mem.eql(u8, key, "value")) {
            tx.value = try parseQuantityU256Value(field);
        } else if (std.mem.eql(u8, key, "nonce")) {
            tx.nonce = try parseQuantityU64Value(field);
        } else if (std.mem.eql(u8, key, "chainId")) {
            _ = try parseQuantityU64Value(field);
        } else if (std.mem.eql(u8, key, "type")) {
            _ = try parseQuantityLikeValue(field);
        } else if (std.mem.eql(u8, key, "accessList")) {
            try parseAccessListCounts(field, &tx);
        } else if (std.mem.eql(u8, key, "blobVersionedHashes") or
            std.mem.eql(u8, key, "authorizationList") or
            std.mem.eql(u8, key, "blobs") or
            std.mem.eql(u8, key, "commitments") or
            std.mem.eql(u8, key, "proofs"))
        {
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

fn parseAccessListCounts(value: std.json.Value, tx: *TransactionRequest) !void {
    const entries = try arrayItemsValue(value);
    tx.access_list_addresses = @intCast(entries.len);
    tx.access_list_storage_keys = 0;
    for (entries) |entry_value| {
        const entry = switch (entry_value) {
            .object => |object| object,
            else => return error.InvalidParams,
        };
        _ = try parseAddressValue(entry.get("address") orelse return error.InvalidParams);
        const storage_keys = try arrayItemsValue(entry.get("storageKeys") orelse return error.InvalidParams);
        for (storage_keys) |slot| {
            _ = try rpc_parse.parseHash32Value(slot);
        }
        tx.access_list_storage_keys += @intCast(storage_keys.len);
    }
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
            block_ctx.block_prevrandao = try parseQuantityU256Value(field);
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
                try applyStorageOverrides(rt, address, field_value);
            } else if (std.mem.eql(u8, field_name, "stateDiff")) {
                try applyStorageOverrides(rt, address, field_value);
            } else if (std.mem.eql(u8, field_name, "movePrecompileToAddress")) {
                _ = try parseAddressValue(field_value);
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

fn successfulSimulateCallValue(allocator: std.mem.Allocator, result: ExecutionResult) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &cleanup);
    }
    try putOwnedJsonValue(&obj, allocator, "status", .{ .string = try allocator.dupe(u8, "0x1") });
    try putOwnedJsonValue(&obj, allocator, "returnData", try hexBytes(allocator, result.output));
    try putOwnedJsonValue(&obj, allocator, "gasUsed", try hexQuantity(allocator, result.gas_used));
    try putOwnedJsonValue(&obj, allocator, "maxUsedGas", try hexQuantity(allocator, result.gas_used));
    try putOwnedJsonValue(&obj, allocator, "logs", .{ .array = std.json.Array.init(allocator) });
    return .{ .object = obj };
}

fn failedSimulateCallValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &cleanup);
    }
    var err_obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = err_obj };
        deinitJsonValue(allocator, &cleanup);
    }
    try putOwnedJsonValue(&err_obj, allocator, "code", .{ .integer = -32000 });
    try putOwnedJsonValue(&err_obj, allocator, "message", .{ .string = try allocator.dupe(u8, "execution reverted") });
    try putOwnedJsonValue(&obj, allocator, "status", .{ .string = try allocator.dupe(u8, "0x0") });
    try putOwnedJsonValue(&obj, allocator, "returnData", .{ .string = try allocator.dupe(u8, "0x") });
    try putOwnedJsonValue(&obj, allocator, "gasUsed", .{ .string = try allocator.dupe(u8, "0x0") });
    try putOwnedJsonValue(&obj, allocator, "maxUsedGas", .{ .string = try allocator.dupe(u8, "0x0") });
    try putOwnedJsonValue(&obj, allocator, "error", .{ .object = err_obj });
    return .{ .object = obj };
}

fn simulatedBlockValue(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    block_ctx: guillotine_mini.BlockContext,
    parent_hash: [32]u8,
    block_hash: [32]u8,
    gas_used: u64,
    calls: std.json.Array,
    return_full_transactions: bool,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &cleanup);
    }

    const state_root = block_builder.computeStateRoot(allocator, &rt.state) catch primitives.State.EMPTY_TRIE_ROOT;
    const zero_nonce = [_]u8{0} ** 8;
    const zero_bloom = [_]u8{0} ** 256;
    const zero_hash = [_]u8{0} ** 32;
    const empty_requests_hash = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    _ = return_full_transactions;

    try putOwnedJsonValue(&obj, allocator, "hash", try hashValue(allocator, block_hash));
    try putOwnedJsonValue(&obj, allocator, "parentHash", try hashValue(allocator, parent_hash));
    try putOwnedJsonValue(&obj, allocator, "sha3Uncles", try hashValue(allocator, primitives.BlockHeader.EMPTY_OMMERS_HASH));
    try putOwnedJsonValue(&obj, allocator, "miner", try addressValue(allocator, block_ctx.block_coinbase));
    try putOwnedJsonValue(&obj, allocator, "stateRoot", try hashValue(allocator, state_root));
    try putOwnedJsonValue(&obj, allocator, "transactionsRoot", try hashValue(allocator, primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT));
    try putOwnedJsonValue(&obj, allocator, "receiptsRoot", try hashValue(allocator, primitives.BlockHeader.EMPTY_RECEIPTS_ROOT));
    try putOwnedJsonValue(&obj, allocator, "logsBloom", try fixedBytesValue(allocator, &zero_bloom));
    try putOwnedJsonValue(&obj, allocator, "difficulty", .{ .string = try allocator.dupe(u8, "0x0") });
    try putOwnedJsonValue(&obj, allocator, "number", try hexQuantity(allocator, block_ctx.block_number));
    try putOwnedJsonValue(&obj, allocator, "parentBeaconBlockRoot", try hashValue(allocator, zero_hash));
    try putOwnedJsonValue(&obj, allocator, "gasLimit", try hexQuantity(allocator, block_ctx.block_gas_limit));
    try putOwnedJsonValue(&obj, allocator, "gasUsed", try hexQuantity(allocator, gas_used));
    try putOwnedJsonValue(&obj, allocator, "timestamp", try hexQuantity(allocator, block_ctx.block_timestamp));
    try putOwnedJsonValue(&obj, allocator, "extraData", .{ .string = try allocator.dupe(u8, "0x") });
    try putOwnedJsonValue(&obj, allocator, "mixHash", try hashValue(allocator, intToHash(block_ctx.block_prevrandao)));
    try putOwnedJsonValue(&obj, allocator, "nonce", try fixedBytesValue(allocator, &zero_nonce));
    try putOwnedJsonValue(&obj, allocator, "baseFeePerGas", try hexQuantityU256(allocator, block_ctx.block_base_fee));
    try putOwnedJsonValue(&obj, allocator, "blobGasUsed", .{ .string = try allocator.dupe(u8, "0x0") });
    try putOwnedJsonValue(&obj, allocator, "excessBlobGas", .{ .string = try allocator.dupe(u8, "0x0") });
    try putOwnedJsonValue(&obj, allocator, "requestsHash", try hashValue(allocator, empty_requests_hash));
    try putOwnedJsonValue(&obj, allocator, "size", .{ .string = try allocator.dupe(u8, "0x0") });
    try putOwnedJsonValue(&obj, allocator, "transactions", .{ .array = std.json.Array.init(allocator) });
    try putOwnedJsonValue(&obj, allocator, "uncles", .{ .array = std.json.Array.init(allocator) });
    try putOwnedJsonValue(&obj, allocator, "withdrawals", .{ .array = std.json.Array.init(allocator) });
    try putOwnedJsonValue(&obj, allocator, "withdrawalsRoot", try hashValue(allocator, primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT));
    try putOwnedJsonValue(&obj, allocator, "calls", .{ .array = calls });
    return .{ .object = obj };
}

fn simulatedBlockHash(number: u64, parent_hash: [32]u8) [32]u8 {
    var input: [40]u8 = undefined;
    @memcpy(input[0..32], &parent_hash);
    std.mem.writeInt(u64, input[32..40], number, .big);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&input, &out, .{});
    return out;
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
