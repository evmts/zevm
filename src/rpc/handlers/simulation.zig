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

const TransactionRequest = struct {
    from: ?primitives.Address = null,
    to: ?primitives.Address = null,
    gas: ?u64 = null,
    gas_price: ?u256 = null,
    value: u256 = 0,
    nonce: ?u64 = null,
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

const ExecutionResult = struct {
    output: []u8,
    gas_used: u64,

    fn deinit(self: *ExecutionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

pub fn handleEthCall(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
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
        } else if (std.mem.eql(u8, key, "value")) {
            tx.value = try parseQuantityU256Value(field);
        } else if (std.mem.eql(u8, key, "nonce")) {
            tx.nonce = try parseQuantityU64Value(field);
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
    const intrinsic = intrinsicGas(rt, tx, block_ctx);
    if (intrinsic > gas_limit or gas_limit > block_ctx.block_gas_limit) return error.ExecutionFailed;
    const execution_gas = gas_limit - intrinsic;

    try rt.state.checkpoint();
    defer rt.state.revert();

    const caller = tx.from orelse rt.coinbase;
    const current_nonce = rt.state.getNonce(caller) catch return error.ExecutionFailed;
    if (tx.nonce) |nonce| {
        if (current_nonce != nonce) return error.ExecutionFailed;
    }

    var adapter = host_adapter.HostAdapter{ .state = &rt.state };
    const host = adapter.hostInterface();

    const EvmType = guillotine_mini.Evm(.{});
    var evm: EvmType = undefined;
    evm.init(
        allocator,
        host,
        rt.hardforkForBlockContext(block_ctx),
        block_ctx,
        caller,
        tx.gas_price orelse rt.gas_price,
        null,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ExecutionFailed,
    };
    defer evm.deinit();

    return if (tx.to) |to|
        executeCall(allocator, &evm, &adapter, caller, to, tx, execution_gas, intrinsic)
    else blk: {
        if (current_nonce == std.math.maxInt(u64)) return error.ExecutionFailed;
        rt.state.setNonce(caller, current_nonce + 1) catch return error.ExecutionFailed;
        break :blk try executeCreate(allocator, &evm, &adapter, tx, execution_gas, intrinsic);
    };
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
    if (!owned.success) return error.ExecutionFailed;

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
    if (!result.success) return error.ExecutionFailed;

    const gas_consumed = if (result.gas_left > execution_gas) 0 else execution_gas - result.gas_left;
    return .{
        .output = try allocator.dupe(u8, result.output),
        .gas_used = intrinsic + gas_consumed,
    };
}

fn gasLimit(tx: TransactionRequest, block_ctx: guillotine_mini.BlockContext) u64 {
    return tx.gas orelse block_ctx.block_gas_limit;
}

fn intrinsicGas(rt: *const runtime.NodeRuntime, tx: TransactionRequest, block_ctx: guillotine_mini.BlockContext) u64 {
    return tx_processor.intrinsicGasForFork(tx.data, tx.to == null, rt.hardforkForBlockContext(block_ctx));
}

fn blockContext(
    rt: *runtime.NodeRuntime,
    block_number: u64,
    recent_block_hashes: *[256][32]u8,
) !guillotine_mini.BlockContext {
    if (block_number == rt.head_block_number) {
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
    }

    const block = (try rt.blockchain.getBlockByNumber(block_number)) orelse return error.InvalidParams;
    var ctx = guillotine_mini.BlockContext{
        .chain_id = rt.chain_id,
        .block_number = block.header.number,
        .block_timestamp = block.header.timestamp,
        .block_difficulty = 0,
        .block_prevrandao = 0,
        .block_coinbase = block.header.beneficiary,
        .block_gas_limit = block.header.gas_limit,
        .block_base_fee = block.header.base_fee_per_gas orelse 0,
        .blob_base_fee = rt.blob_base_fee,
    };
    ctx.block_hashes = try rt.recentBlockHashesForExecution(ctx.block_number, recent_block_hashes);
    return ctx;
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

fn writeHexLower(out: []u8, bytes: []const u8) void {
    const charset = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = charset[(byte >> 4) & 0x0f];
        out[i * 2 + 1] = charset[byte & 0x0f];
    }
}
