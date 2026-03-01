const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const guillotine_mini = @import("guillotine_mini");
const state_manager = @import("state-manager");
const runtime = @import("../node/runtime.zig");
const tx_submission = @import("handlers/tx_submission.zig");
const eth_read = @import("handlers/eth_read.zig");
const block_query_handlers = @import("handlers/block_query_handlers.zig");
const dev_runtime = @import("dev_runtime.zig");
const dev_handlers = @import("dev_handlers.zig");
const receipt_index = @import("../receipt_index.zig");
const log_index = @import("../log_index.zig");
const tx_processor = @import("../tx_processor.zig");
const host_adapter = @import("../host_adapter.zig");

const FilterKind = enum {
    log,
    block,
    pending_transaction,
    subscription,
};

const FilterState = struct {
    kind: FilterKind,
    last_block: u64,
};

const CallRequest = struct {
    from: primitives.Address,
    to: ?primitives.Address,
    gas: u64,
    gas_price: u256,
    value: u256,
    nonce: ?u64,
    data: []u8,
};

pub const NodeHandler = struct {
    node_runtime: runtime.NodeRuntime,
    dev_runtime: dev_runtime.DevRuntime,
    receipt_index: receipt_index.ReceiptIndex,
    log_index: log_index.LogIndex,
    next_filter_id: u64,
    filters: std.AutoHashMap(u64, FilterState),

    pub fn init(allocator: std.mem.Allocator, config: ?runtime.NodeConfig) !NodeHandler {
        var node_runtime = try runtime.NodeRuntime.init(allocator, config);
        errdefer node_runtime.deinit(allocator);

        return .{
            .node_runtime = node_runtime,
            .dev_runtime = dev_runtime.DevRuntime.init(),
            .receipt_index = receipt_index.ReceiptIndex.init(allocator),
            .log_index = log_index.LogIndex.init(),
            .next_filter_id = 1,
            .filters = std.AutoHashMap(u64, FilterState).init(allocator),
        };
    }

    pub fn deinit(self: *NodeHandler, allocator: std.mem.Allocator) void {
        self.filters.deinit();
        self.log_index.deinit(allocator);
        self.receipt_index.deinit(allocator);
        self.dev_runtime.deinit(allocator);
        self.node_runtime.deinit(allocator);
    }

    pub fn onMethod(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        method_name: []const u8,
        params: ?std.json.Value,
    ) !std.json.Value {
        const self: *NodeHandler = @ptrCast(@alignCast(context));
        return self.dispatchMethod(allocator, method_name, params);
    }

    fn dispatchMethod(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        method_name: []const u8,
        params: ?std.json.Value,
    ) !std.json.Value {
        if (std.mem.eql(u8, method_name, "eth_chainId")) {
            const parsed = try parseParams(jsonrpc.eth.ChainId.Params, allocator, params);
            const result = try eth_read.handleEthChainId(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_blockNumber")) {
            const parsed = try parseParams(jsonrpc.eth.BlockNumber.Params, allocator, params);
            const result = try eth_read.handleEthBlockNumber(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getBalance")) {
            const parsed = try parseParams(jsonrpc.eth.GetBalance.Params, allocator, params);
            const result = try eth_read.handleEthGetBalance(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getCode")) {
            const parsed = try parseParams(jsonrpc.eth.GetCode.Params, allocator, params);
            const result = try eth_read.handleEthGetCode(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getStorageAt")) {
            const parsed = try parseParams(jsonrpc.eth.GetStorageAt.Params, allocator, params);
            const result = try eth_read.handleEthGetStorageAt(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getTransactionCount")) {
            const parsed = try parseParams(jsonrpc.eth.GetTransactionCount.Params, allocator, params);
            const result = try eth_read.handleEthGetTransactionCount(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_gasPrice")) {
            const parsed = try parseParams(jsonrpc.eth.GasPrice.Params, allocator, params);
            const result = try eth_read.handleEthGasPrice(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_coinbase")) {
            const parsed = try parseParams(jsonrpc.eth.Coinbase.Params, allocator, params);
            const result = try eth_read.handleEthCoinbase(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_accounts")) {
            const parsed = try parseParams(jsonrpc.eth.Accounts.Params, allocator, params);
            const result = try eth_read.handleEthAccounts(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_maxPriorityFeePerGas")) {
            const parsed = try parseParams(jsonrpc.eth.MaxPriorityFeePerGas.Params, allocator, params);
            const result = try eth_read.handleEthMaxPriorityFeePerGas(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_blobBaseFee")) {
            const parsed = try parseParams(jsonrpc.eth.BlobBaseFee.Params, allocator, params);
            const result = try eth_read.handleEthBlobBaseFee(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_feeHistory")) {
            const parsed = try parseParams(jsonrpc.eth.FeeHistory.Params, allocator, params);
            const result = try eth_read.handleEthFeeHistory(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_sendRawTransaction")) {
            const parsed = try parseParams(jsonrpc.eth.SendRawTransaction.Params, allocator, params);
            const result = try tx_submission.handleSendRawTransaction(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_sendTransaction")) {
            const parsed = try parseParams(jsonrpc.eth.SendTransaction.Params, allocator, params);
            const result = try tx_submission.handleSendTransaction(allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getBlockByNumber")) {
            const parsed = try parseParams(jsonrpc.eth.GetBlockByNumber.Params, allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetBlockByNumber(allocator, &block_query_context, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getBlockByHash")) {
            const parsed = try parseParams(jsonrpc.eth.GetBlockByHash.Params, allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetBlockByHash(allocator, &block_query_context, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getTransactionReceipt")) {
            const parsed = try parseParams(jsonrpc.eth.GetTransactionReceipt.Params, allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetTransactionReceipt(allocator, &block_query_context, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getBlockReceipts")) {
            const parsed = try parseParams(jsonrpc.eth.GetBlockReceipts.Params, allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetBlockReceipts(allocator, &block_query_context, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getLogs")) {
            const parsed = try parseParams(jsonrpc.eth.GetLogs.Params, allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetLogs(allocator, &block_query_context, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getTransactionByHash")) {
            const parsed = try parseParams(jsonrpc.eth.GetTransactionByHash.Params, allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetTransactionByHash(allocator, &block_query_context, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_call")) {
            const call_result = try self.executeEthCall(allocator, params);
            return .{ .string = call_result };
        }
        if (std.mem.eql(u8, method_name, "eth_estimateGas")) {
            const estimated = try self.estimateGas(allocator, params);
            return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{estimated}) };
        }
        if (std.mem.eql(u8, method_name, "evm_snapshot")) {
            self.dev_runtime.config.coinbase = self.node_runtime.coinbase;
            self.dev_runtime.config.next_block_base_fee_per_gas = self.node_runtime.next_block_base_fee_override;
            self.dev_runtime.config.block_gas_limit = self.node_runtime.block_gas_limit;
            const result = try dev_handlers.handleEvmSnapshot(
                allocator,
                &self.dev_runtime,
                &self.node_runtime.state,
                self.node_runtime.head_block_number,
            );
            return result;
        }
        if (std.mem.eql(u8, method_name, "evm_revert")) {
            const snapshot_id = parseFirstU64(params) orelse return error.InvalidParams;
            const snapshot_entry = self.dev_runtime.snapshots.get(snapshot_id) orelse return .{ .bool = false };
            const result = try dev_handlers.handleEvmRevert(
                allocator,
                &self.dev_runtime,
                &self.node_runtime.state,
                &self.node_runtime.blockchain,
                params,
            );
            if (result.bool) {
                self.node_runtime.head_block_number = snapshot_entry.block_number;
                self.node_runtime.coinbase = snapshot_entry.config.coinbase;
                self.node_runtime.next_block_base_fee_override = snapshot_entry.config.next_block_base_fee_per_gas;
                self.node_runtime.block_gas_limit = snapshot_entry.config.block_gas_limit;
            }
            return result;
        }
        if (std.mem.eql(u8, method_name, "evm_setBlockGasLimit")) {
            const result = try dev_handlers.handleEvmSetBlockGasLimit(&self.dev_runtime, params);
            self.node_runtime.block_gas_limit = self.dev_runtime.config.block_gas_limit;
            return result;
        }
        if (std.mem.eql(u8, method_name, "hardhat_setBalance") or std.mem.eql(u8, method_name, "anvil_setBalance")) {
            return try dev_handlers.handleHardhatSetBalance(&self.node_runtime.state, params);
        }
        if (std.mem.eql(u8, method_name, "hardhat_setCode") or std.mem.eql(u8, method_name, "anvil_setCode")) {
            return try dev_handlers.handleHardhatSetCode(allocator, &self.node_runtime.state, params);
        }
        if (std.mem.eql(u8, method_name, "hardhat_setNonce") or std.mem.eql(u8, method_name, "anvil_setNonce")) {
            return try dev_handlers.handleHardhatSetNonce(&self.node_runtime.state, params);
        }
        if (std.mem.eql(u8, method_name, "hardhat_setStorageAt") or std.mem.eql(u8, method_name, "anvil_setStorageAt")) {
            return try dev_handlers.handleHardhatSetStorageAt(&self.node_runtime.state, params);
        }
        if (std.mem.eql(u8, method_name, "hardhat_setCoinbase") or std.mem.eql(u8, method_name, "anvil_setCoinbase")) {
            const result = try dev_handlers.handleHardhatSetCoinbase(&self.dev_runtime, params);
            self.node_runtime.coinbase = self.dev_runtime.config.coinbase;
            return result;
        }
        if (std.mem.eql(u8, method_name, "hardhat_setNextBlockBaseFeePerGas") or std.mem.eql(u8, method_name, "anvil_setNextBlockBaseFeePerGas")) {
            const result = try dev_handlers.handleHardhatSetNextBlockBaseFeePerGas(&self.dev_runtime, params);
            self.node_runtime.next_block_base_fee_override = self.dev_runtime.config.next_block_base_fee_per_gas;
            return result;
        }
        if (std.mem.eql(u8, method_name, "hardhat_impersonateAccount")) {
            const address = parseFirstAddress(params) orelse return error.InvalidParams;
            try self.node_runtime.impersonateAccount(allocator, address);
            return .{ .bool = true };
        }
        if (std.mem.eql(u8, method_name, "hardhat_stopImpersonatingAccount")) {
            const address = parseFirstAddress(params) orelse return error.InvalidParams;
            self.node_runtime.stopImpersonatingAccount(address);
            return .{ .bool = true };
        }
        if (std.mem.eql(u8, method_name, "evm_increaseTime")) {
            const delta = parseFirstU64(params) orelse return error.InvalidParams;
            self.node_runtime.current_timestamp +%= delta;
            return .{ .integer = @intCast(delta) };
        }
        if (std.mem.eql(u8, method_name, "evm_setNextBlockTimestamp")) {
            const timestamp = parseFirstU64(params) orelse return error.InvalidParams;
            self.node_runtime.next_block_timestamp_override = timestamp;
            return .{ .bool = true };
        }
        if (std.mem.eql(u8, method_name, "hardhat_setPrevRandao")) {
            const value = parseFirstU256(params) orelse return error.InvalidParams;
            self.node_runtime.prev_randao = value;
            return .{ .bool = true };
        }
        if (std.mem.eql(u8, method_name, "evm_mine") or std.mem.eql(u8, method_name, "hardhat_mine")) {
            const count = parseOptionalCount(params);
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                if (self.node_runtime.pool.pendingCount() > 0) {
                    try tx_submission.minePendingTransactions(allocator, &self.node_runtime);
                } else {
                    const next_timestamp: u64 = self.node_runtime.next_block_timestamp_override orelse self.node_runtime.current_timestamp + 1;
                    const next_base_fee: u256 = self.node_runtime.next_block_base_fee_override orelse self.node_runtime.base_fee;
                    self.node_runtime.head_block_number += 1;
                    self.node_runtime.current_timestamp = next_timestamp;
                    self.node_runtime.base_fee = next_base_fee;
                    self.node_runtime.next_block_timestamp_override = null;
                    self.node_runtime.next_block_base_fee_override = null;
                }
            }
            return .{ .string = "0x0" };
        }
        if (std.mem.eql(u8, method_name, "eth_newFilter")) {
            const id = self.next_filter_id;
            self.next_filter_id += 1;
            try self.filters.put(id, .{ .kind = .log, .last_block = self.node_runtime.head_block_number });
            return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{id}) };
        }
        if (std.mem.eql(u8, method_name, "eth_newBlockFilter")) {
            const id = self.next_filter_id;
            self.next_filter_id += 1;
            try self.filters.put(id, .{ .kind = .block, .last_block = self.node_runtime.head_block_number });
            return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{id}) };
        }
        if (std.mem.eql(u8, method_name, "eth_newPendingTransactionFilter")) {
            const id = self.next_filter_id;
            self.next_filter_id += 1;
            try self.filters.put(id, .{ .kind = .pending_transaction, .last_block = self.node_runtime.head_block_number });
            return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{id}) };
        }
        if (std.mem.eql(u8, method_name, "eth_getFilterChanges")) {
            return try self.handleGetFilterChanges(allocator, params);
        }
        if (std.mem.eql(u8, method_name, "eth_getFilterLogs")) {
            return .{ .array = std.json.Array.init(allocator) };
        }
        if (std.mem.eql(u8, method_name, "eth_uninstallFilter")) {
            const id = parseFirstU64(params) orelse return error.InvalidParams;
            return .{ .bool = self.filters.remove(id) };
        }
        if (std.mem.eql(u8, method_name, "eth_subscribe")) {
            const id = self.next_filter_id;
            self.next_filter_id += 1;
            try self.filters.put(id, .{ .kind = .subscription, .last_block = self.node_runtime.head_block_number });
            return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{id}) };
        }
        if (std.mem.eql(u8, method_name, "eth_unsubscribe")) {
            const id = parseFirstU64(params) orelse return error.InvalidParams;
            return .{ .bool = self.filters.remove(id) };
        }
        if (std.mem.eql(u8, method_name, "debug_traceCall")) {
            return try simpleTraceResult(allocator);
        }
        if (std.mem.eql(u8, method_name, "debug_traceTransaction")) {
            return try simpleTraceResult(allocator);
        }
        return error.MethodNotFound;
    }

    fn executeEthCall(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        params: ?std.json.Value,
    ) ![]const u8 {
        const call = parseCallRequest(
            allocator,
            params,
            self.node_runtime.coinbase,
            self.node_runtime.block_gas_limit,
            self.node_runtime.gas_price,
        ) catch return error.InvalidParams;
        defer allocator.free(call.data);

        const overrides = extractStateOverrides(params);

        try self.node_runtime.state.checkpoint();
        defer self.node_runtime.state.revert();

        if (overrides) |value| {
            try applyStateOverrides(allocator, &self.node_runtime.state, value);
        }

        const block_ctx = guillotine_mini.BlockContext{
            .chain_id = self.node_runtime.chain_id,
            .block_number = self.node_runtime.head_block_number,
            .block_timestamp = self.node_runtime.current_timestamp,
            .block_difficulty = 0,
            .block_prevrandao = self.node_runtime.prev_randao,
            .block_coinbase = self.node_runtime.coinbase,
            .block_gas_limit = self.node_runtime.block_gas_limit,
            .block_base_fee = self.node_runtime.base_fee,
            .blob_base_fee = self.node_runtime.blob_base_fee,
        };

        var adapter = host_adapter.HostAdapter{ .state = &self.node_runtime.state };
        const host_iface = adapter.hostInterface();

        const EvmType = guillotine_mini.Evm(.{});
        var evm: EvmType = undefined;
        evm.init(allocator, host_iface, null, block_ctx, null) catch return error.InvalidParams;
        defer evm.deinit();
        evm.initTransactionState(null) catch return error.InvalidParams;

        const gas_limit = @min(call.gas, self.node_runtime.block_gas_limit);
        const call_params: EvmType.CallParams = if (call.to) |to|
            .{ .call = .{
                .caller = call.from,
                .to = to,
                .value = call.value,
                .input = call.data,
                .gas = gas_limit,
            } }
        else
            .{ .create = .{
                .caller = call.from,
                .value = call.value,
                .init_code = call.data,
                .gas = gas_limit,
            } };

        var result = evm.call(call_params).toOwnedResult(allocator) catch return error.InvalidParams;
        defer result.deinit(allocator);

        return try std.fmt.allocPrint(allocator, "0x{x}", .{result.output});
    }

    fn estimateGas(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        params: ?std.json.Value,
    ) !u64 {
        const call = parseCallRequest(
            allocator,
            params,
            self.node_runtime.coinbase,
            self.node_runtime.block_gas_limit,
            self.node_runtime.gas_price,
        ) catch return error.InvalidParams;
        defer allocator.free(call.data);

        const overrides = extractStateOverrides(params);
        const lower_bound = tx_processor.intrinsicGas(call.data, call.to == null);
        var upper_bound = @min(call.gas, self.node_runtime.block_gas_limit);
        if (upper_bound == 0) upper_bound = self.node_runtime.block_gas_limit;
        if (upper_bound < lower_bound) return error.InvalidParams;

        if (!(try self.simulateEstimateCandidate(allocator, call, overrides, upper_bound))) {
            return error.InvalidParams;
        }

        var low = lower_bound;
        var high = upper_bound;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (try self.simulateEstimateCandidate(allocator, call, overrides, mid)) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return low;
    }

    fn simulateEstimateCandidate(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        call: CallRequest,
        overrides: ?std.json.Value,
        gas_limit: u64,
    ) !bool {
        try self.node_runtime.state.checkpoint();
        defer self.node_runtime.state.revert();

        if (overrides) |value| {
            try applyStateOverrides(allocator, &self.node_runtime.state, value);
        }

        const nonce = call.nonce orelse (self.node_runtime.getNonceWithFork(allocator, call.from) catch return false);

        const tx = primitives.Transaction.LegacyTransaction{
            .nonce = nonce,
            .gas_price = call.gas_price,
            .gas_limit = gas_limit,
            .to = call.to,
            .value = call.value,
            .data = call.data,
            .v = 0,
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        };

        const block_ctx = guillotine_mini.BlockContext{
            .chain_id = self.node_runtime.chain_id,
            .block_number = self.node_runtime.head_block_number,
            .block_timestamp = self.node_runtime.current_timestamp,
            .block_difficulty = 0,
            .block_prevrandao = self.node_runtime.prev_randao,
            .block_coinbase = self.node_runtime.coinbase,
            .block_gas_limit = self.node_runtime.block_gas_limit,
            .block_base_fee = self.node_runtime.base_fee,
            .blob_base_fee = self.node_runtime.blob_base_fee,
        };

        var adapter = host_adapter.HostAdapter{ .state = &self.node_runtime.state };
        const host_iface = adapter.hostInterface();
        var receipt = tx_processor.processTransaction(
            allocator,
            &self.node_runtime.state,
            host_iface,
            call.from,
            tx,
            block_ctx,
        ) catch return false;
        defer receipt.deinit(allocator);

        if (receipt.status) |status| {
            return status.success;
        }
        return true;
    }

    fn handleGetFilterChanges(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        params: ?std.json.Value,
    ) !std.json.Value {
        const id = parseFirstU64(params) orelse return error.InvalidParams;
        const state = self.filters.getPtr(id) orelse return .{ .array = std.json.Array.init(allocator) };

        switch (state.kind) {
            .block => {
                var result_array = std.json.Array.init(allocator);
                if (self.node_runtime.head_block_number > state.last_block) {
                    const block_hash = syntheticBlockHash(self.node_runtime.head_block_number, self.node_runtime.current_timestamp);
                    try result_array.append(.{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{block_hash}) });
                    state.last_block = self.node_runtime.head_block_number;
                }
                return .{ .array = result_array };
            },
            .pending_transaction, .log, .subscription => {
                return .{ .array = std.json.Array.init(allocator) };
            },
        }
    }
};

fn parseParams(comptime T: type, allocator: std.mem.Allocator, params: ?std.json.Value) !T {
    var source: std.json.Value = undefined;
    if (params) |existing| {
        source = existing;
    } else {
        source = .{ .array = std.json.Array.init(allocator) };
    }
    if (@hasDecl(T, "jsonParseFromValue")) {
        return T.jsonParseFromValue(allocator, source, .{}) catch return error.InvalidParams;
    }
    return std.json.innerParseFromValue(T, allocator, source, .{}) catch return error.InvalidParams;
}

fn toJsonValue(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    try std.json.Stringify.value(value, .{}, &writer.writer);
    const bytes = try writer.toOwnedSlice();
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    });
    return parsed.value;
}

fn makeBlockQueryContext(self: *NodeHandler) block_query_handlers.BlockQueryContext {
    return .{
        .rt = &self.node_runtime,
        .blockchain = &self.node_runtime.blockchain,
        .receipt_index = &self.receipt_index,
        .log_index = &self.log_index,
    };
}

fn parseCallRequest(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
    default_from: primitives.Address,
    default_gas: u64,
    default_gas_price: u256,
) !CallRequest {
    const array = switch (params orelse return error.InvalidParams) {
        .array => |arr| arr.items,
        else => return error.InvalidParams,
    };
    if (array.len == 0) return error.InvalidParams;

    const object = switch (array[0]) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };

    const from = blk: {
        if (object.get("from")) |from_value| {
            const from_string = switch (from_value) {
                .string => |string| string,
                else => break :blk default_from,
            };
            break :blk parseAddressFromHex(from_string) orelse return error.InvalidParams;
        }
        break :blk default_from;
    };

    const to = blk: {
        if (object.get("to")) |to_value| {
            const to_string = switch (to_value) {
                .string => |string| string,
                .null => break :blk null,
                else => return error.InvalidParams,
            };
            break :blk parseAddressFromHex(to_string) orelse return error.InvalidParams;
        }
        break :blk null;
    };

    const gas = blk: {
        if (object.get("gas")) |gas_value| {
            break :blk parseJsonQuantityToU64(gas_value) orelse return error.InvalidParams;
        }
        break :blk default_gas;
    };

    const gas_price = blk: {
        if (object.get("gasPrice")) |gas_price_value| {
            break :blk parseJsonQuantityToU256(gas_price_value) orelse return error.InvalidParams;
        }
        if (object.get("maxFeePerGas")) |max_fee| {
            break :blk parseJsonQuantityToU256(max_fee) orelse return error.InvalidParams;
        }
        break :blk default_gas_price;
    };

    const value = blk: {
        if (object.get("value")) |value_field| {
            break :blk parseJsonQuantityToU256(value_field) orelse return error.InvalidParams;
        }
        break :blk 0;
    };

    const nonce = blk: {
        if (object.get("nonce")) |nonce_value| {
            break :blk parseJsonQuantityToU64(nonce_value) orelse return error.InvalidParams;
        }
        break :blk null;
    };

    const data_hex = blk: {
        if (object.get("data") orelse object.get("input")) |data_value| {
            const data_string = switch (data_value) {
                .string => |string| string,
                else => return error.InvalidParams,
            };
            break :blk data_string;
        }
        break :blk "0x";
    };

    const data = try parseHexBytesOwned(allocator, data_hex);
    return .{
        .from = from,
        .to = to,
        .gas = gas,
        .gas_price = gas_price,
        .value = value,
        .nonce = nonce,
        .data = data,
    };
}

fn extractStateOverrides(params: ?std.json.Value) ?std.json.Value {
    const array = switch (params orelse return null) {
        .array => |arr| arr.items,
        else => return null,
    };
    if (array.len < 3) return null;
    return array[2];
}

fn applyStateOverrides(
    allocator: std.mem.Allocator,
    state: *state_manager.StateManager,
    overrides: std.json.Value,
) !void {
    const accounts = switch (overrides) {
        .object => |obj| obj,
        .null => return,
        else => return error.InvalidParams,
    };

    var account_it = accounts.iterator();
    while (account_it.next()) |entry| {
        const address = parseAddressFromHex(entry.key_ptr.*) orelse return error.InvalidParams;
        const account_override = switch (entry.value_ptr.*) {
            .object => |obj| obj,
            else => return error.InvalidParams,
        };

        if (account_override.get("balance")) |balance_value| {
            const balance = parseJsonQuantityToU256(balance_value) orelse return error.InvalidParams;
            try state.setBalance(address, balance);
        }
        if (account_override.get("nonce")) |nonce_value| {
            const nonce = parseJsonQuantityToU64(nonce_value) orelse return error.InvalidParams;
            try state.setNonce(address, nonce);
        }
        if (account_override.get("code")) |code_value| {
            const code = try parseHexBytesOwned(allocator, switch (code_value) {
                .string => |s| s,
                else => return error.InvalidParams,
            });
            defer allocator.free(code);
            try state.setCode(address, code);
        }

        if (account_override.get("state")) |full_state| {
            try applyStorageOverrideMap(state, address, full_state);
        }
        if (account_override.get("stateDiff")) |state_diff| {
            try applyStorageOverrideMap(state, address, state_diff);
        }
    }
}

fn applyStorageOverrideMap(
    state: *state_manager.StateManager,
    address: primitives.Address,
    mapping_value: std.json.Value,
) !void {
    const mapping = switch (mapping_value) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };

    var slot_it = mapping.iterator();
    while (slot_it.next()) |entry| {
        const slot = parseHexU256String(entry.key_ptr.*) orelse return error.InvalidParams;
        const value = parseJsonQuantityToU256(entry.value_ptr.*) orelse return error.InvalidParams;
        try state.setStorage(address, slot, value);
    }
}

fn parseFirstAddress(params: ?std.json.Value) ?primitives.Address {
    const array = switch (params orelse return null) {
        .array => |arr| arr.items,
        else => return null,
    };
    if (array.len == 0) return null;
    const value = switch (array[0]) {
        .string => |string| string,
        else => return null,
    };
    return parseAddressFromHex(value);
}

fn parseAddressFromHex(hex: []const u8) ?primitives.Address {
    if (hex.len != 42) return null;
    if (hex[0] != '0' or (hex[1] != 'x' and hex[1] != 'X')) return null;
    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex[2..]) catch return null;
    return .{ .bytes = bytes };
}

fn parseHexBytesOwned(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var hex = value;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
        hex = hex[2..];
    }
    if (hex.len == 0) {
        return allocator.alloc(u8, 0);
    }
    if (hex.len % 2 != 0) return error.InvalidParams;
    const bytes = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(bytes);
    _ = std.fmt.hexToBytes(bytes, hex) catch return error.InvalidParams;
    return bytes;
}

fn parseHexU256String(value: []const u8) ?u256 {
    var hex = value;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
        hex = hex[2..];
    }
    if (hex.len == 0) return 0;
    return std.fmt.parseInt(u256, hex, 16) catch null;
}

fn parseFirstU64(params: ?std.json.Value) ?u64 {
    const array = switch (params orelse return null) {
        .array => |arr| arr.items,
        else => return null,
    };
    if (array.len == 0) return null;
    return parseJsonQuantityToU64(array[0]);
}

fn parseFirstU256(params: ?std.json.Value) ?u256 {
    const array = switch (params orelse return null) {
        .array => |arr| arr.items,
        else => return null,
    };
    if (array.len == 0) return null;
    return parseJsonQuantityToU256(array[0]);
}

fn parseOptionalCount(params: ?std.json.Value) u64 {
    const array = switch (params orelse return 1) {
        .array => |arr| arr.items,
        else => return 1,
    };
    if (array.len == 0) return 1;
    return parseJsonQuantityToU64(array[0]) orelse 1;
}

fn parseJsonQuantityToU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .string => |string| blk: {
            if (string.len >= 2 and string[0] == '0' and (string[1] == 'x' or string[1] == 'X')) {
                break :blk std.fmt.parseInt(u64, string[2..], 16) catch null;
            }
            break :blk std.fmt.parseInt(u64, string, 10) catch null;
        },
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        else => null,
    };
}

fn parseJsonQuantityToU256(value: std.json.Value) ?u256 {
    return switch (value) {
        .string => |string| blk: {
            if (string.len >= 2 and string[0] == '0' and (string[1] == 'x' or string[1] == 'X')) {
                break :blk std.fmt.parseInt(u256, string[2..], 16) catch null;
            }
            break :blk std.fmt.parseInt(u256, string, 10) catch null;
        },
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        else => null,
    };
}

fn simpleTraceResult(allocator: std.mem.Allocator) !std.json.Value {
    var object = std.json.ObjectMap.init(allocator);
    try object.put("gas", .{ .string = "0x0" });
    try object.put("failed", .{ .bool = false });
    try object.put("returnValue", .{ .string = "0x" });
    try object.put("structLogs", .{ .array = std.json.Array.init(allocator) });
    return .{ .object = object };
}

fn intrinsicGasFromHexData(data_hex: []const u8, is_create: bool) u64 {
    var hex = data_hex;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
        hex = hex[2..];
    }
    if (hex.len == 0) {
        return tx_processor.intrinsicGas(&[_]u8{}, is_create);
    }
    const byte_count = hex.len / 2;
    var zeros: usize = 0;
    var i: usize = 0;
    while (i + 1 < hex.len) : (i += 2) {
        if (hexDigitToNibble(hex[i]) == 0 and hexDigitToNibble(hex[i + 1]) == 0) {
            zeros += 1;
        }
    }
    const non_zeros = byte_count - zeros;
    const base: u64 = if (is_create) 53_000 else 21_000;
    return base + @as(u64, @intCast(zeros * 4 + non_zeros * 16));
}

fn hexDigitToNibble(digit: u8) u8 {
    return switch (digit) {
        '0'...'9' => digit - '0',
        'a'...'f' => digit - 'a' + 10,
        'A'...'F' => digit - 'A' + 10,
        else => 0xff,
    };
}

fn syntheticBlockHash(block_number: u64, timestamp: u64) [32]u8 {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], block_number, .big);
    std.mem.writeInt(u64, bytes[8..16], timestamp, .big);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&bytes, &out, .{});
    return out;
}
