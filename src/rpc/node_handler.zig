const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const guillotine_mini = @import("guillotine_mini");
const state_manager = @import("state-manager");
const txpool = @import("txpool");
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

const SubscriptionKind = enum {
    new_heads,
    logs,
    new_pending_transactions,
    syncing,
};

const FilterState = struct {
    kind: FilterKind,
    last_block: u64,
    filter_json: ?[]u8 = null,
    subscription_kind: ?SubscriptionKind = null,
    event_cursor: usize = 0,
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

const TraceExecutionResult = struct {
    gas_used: u64,
    failed: bool,
    output: []u8,
    struct_logs: std.json.Array,
};

const HostForkResolverContext = struct {
    allocator: std.mem.Allocator,
    node_runtime: *runtime.NodeRuntime,
};

fn resolveHostForkPending(context: *anyopaque) bool {
    const typed_context: *HostForkResolverContext = @ptrCast(@alignCast(context));
    return typed_context.node_runtime.processForkRequests(typed_context.allocator) catch false;
}

const RuntimeSnapshot = struct {
    coinbase: primitives.Address,
    block_gas_limit: u64,
    head_block_number: u64,
    head_block_hash: [32]u8,
    current_timestamp: u64,
    base_fee: u256,
    prev_randao: u256,
    next_block_base_fee_override: ?u256,
    next_block_timestamp_override: ?u64,
    mining_mode: runtime.MiningMode,
    interval_seconds: u64,
    tx_index: std.AutoHashMap([32]u8, runtime.TransactionRecord),
    pool: txpool.TxPool,
    pending_tx_events: std.ArrayList([32]u8),
    mined_block_events: std.ArrayList(runtime.BlockEvent),
    impersonated_accounts: std.AutoHashMap(primitives.Address, void),

    fn deinit(self: *RuntimeSnapshot, allocator: std.mem.Allocator) void {
        var tx_it = self.tx_index.valueIterator();
        while (tx_it.next()) |record| {
            allocator.free(record.raw);
        }
        self.tx_index.deinit();
        self.pool.deinit(allocator);
        self.pending_tx_events.deinit(allocator);
        self.mined_block_events.deinit(allocator);
        self.impersonated_accounts.deinit();
    }
};

pub const NodeHandler = struct {
    node_runtime: runtime.NodeRuntime,
    dev_runtime: dev_runtime.DevRuntime,
    receipt_index: receipt_index.ReceiptIndex,
    log_index: log_index.LogIndex,
    next_filter_id: u64,
    filters: std.AutoHashMap(u64, FilterState),
    runtime_snapshots: std.AutoHashMap(u64, RuntimeSnapshot),
    last_interval_mine_ns: ?i128,

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
            .runtime_snapshots = std.AutoHashMap(u64, RuntimeSnapshot).init(allocator),
            .last_interval_mine_ns = null,
        };
    }

    pub fn deinit(self: *NodeHandler, allocator: std.mem.Allocator) void {
        var filter_it = self.filters.valueIterator();
        while (filter_it.next()) |filter_state| {
            if (filter_state.filter_json) |json| {
                allocator.free(json);
            }
        }
        self.filters.deinit();
        var snapshot_it = self.runtime_snapshots.valueIterator();
        while (snapshot_it.next()) |snapshot| {
            snapshot.deinit(allocator);
        }
        self.runtime_snapshots.deinit();
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
        var temp_arena = std.heap.ArenaAllocator.init(allocator);
        defer temp_arena.deinit();
        const temp_allocator = temp_arena.allocator();

        if (std.mem.eql(u8, method_name, "eth_chainId")) {
            const parsed = try parseParams(jsonrpc.eth.ChainId.Params, temp_allocator, params);
            const result = try eth_read.handleEthChainId(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_blockNumber")) {
            const parsed = try parseParams(jsonrpc.eth.BlockNumber.Params, temp_allocator, params);
            const result = try eth_read.handleEthBlockNumber(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getBalance")) {
            const parsed = try parseParams(jsonrpc.eth.GetBalance.Params, temp_allocator, params);
            const result = try eth_read.handleEthGetBalance(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getCode")) {
            const parsed = try parseParams(jsonrpc.eth.GetCode.Params, temp_allocator, params);
            const result = try eth_read.handleEthGetCode(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getStorageAt")) {
            const parsed = try parseParams(jsonrpc.eth.GetStorageAt.Params, temp_allocator, params);
            const result = try eth_read.handleEthGetStorageAt(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getTransactionCount")) {
            const parsed = try parseParams(jsonrpc.eth.GetTransactionCount.Params, temp_allocator, params);
            const result = try eth_read.handleEthGetTransactionCount(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_gasPrice")) {
            const parsed = try parseParams(jsonrpc.eth.GasPrice.Params, temp_allocator, params);
            const result = try eth_read.handleEthGasPrice(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_coinbase")) {
            const parsed = try parseParams(jsonrpc.eth.Coinbase.Params, temp_allocator, params);
            const result = try eth_read.handleEthCoinbase(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_accounts")) {
            const parsed = try parseParams(jsonrpc.eth.Accounts.Params, temp_allocator, params);
            const result = try eth_read.handleEthAccounts(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_maxPriorityFeePerGas")) {
            const parsed = try parseParams(jsonrpc.eth.MaxPriorityFeePerGas.Params, temp_allocator, params);
            const result = try eth_read.handleEthMaxPriorityFeePerGas(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_blobBaseFee")) {
            const parsed = try parseParams(jsonrpc.eth.BlobBaseFee.Params, temp_allocator, params);
            const result = try eth_read.handleEthBlobBaseFee(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_feeHistory")) {
            const parsed = try parseParams(jsonrpc.eth.FeeHistory.Params, temp_allocator, params);
            const result = try eth_read.handleEthFeeHistory(temp_allocator, &self.node_runtime, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_sendRawTransaction")) {
            const parsed = try parseParams(jsonrpc.eth.SendRawTransaction.Params, temp_allocator, params);
            const result = tx_submission.handleSendRawTransaction(allocator, &self.node_runtime, parsed) catch |err| switch (err) {
                tx_submission.TxSubmissionError.InvalidHexData,
                tx_submission.TxSubmissionError.DecodeFailed,
                tx_submission.TxSubmissionError.SenderRecoveryFailed,
                tx_submission.TxSubmissionError.ChainIdMismatch,
                tx_submission.TxSubmissionError.NonceMismatch,
                tx_submission.TxSubmissionError.InsufficientBalance,
                tx_submission.TxSubmissionError.IntrinsicGasExceedsLimit,
                tx_submission.TxSubmissionError.PoolInsertFailed,
                tx_submission.TxSubmissionError.UnmanagedAccount,
                tx_submission.TxSubmissionError.SigningFailed,
                => return error.InvalidParams,
                else => return err,
            };
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_sendTransaction")) {
            const parsed = try parseParams(jsonrpc.eth.SendTransaction.Params, temp_allocator, params);
            const result = tx_submission.handleSendTransaction(allocator, &self.node_runtime, parsed) catch |err| switch (err) {
                tx_submission.TxSubmissionError.InvalidHexData,
                tx_submission.TxSubmissionError.DecodeFailed,
                tx_submission.TxSubmissionError.SenderRecoveryFailed,
                tx_submission.TxSubmissionError.ChainIdMismatch,
                tx_submission.TxSubmissionError.NonceMismatch,
                tx_submission.TxSubmissionError.InsufficientBalance,
                tx_submission.TxSubmissionError.IntrinsicGasExceedsLimit,
                tx_submission.TxSubmissionError.PoolInsertFailed,
                tx_submission.TxSubmissionError.UnmanagedAccount,
                tx_submission.TxSubmissionError.SigningFailed,
                => return error.InvalidParams,
                else => return err,
            };
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getBlockByNumber")) {
            const parsed = try parseParams(jsonrpc.eth.GetBlockByNumber.Params, temp_allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetBlockByNumber(temp_allocator, &block_query_context, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getBlockByHash")) {
            const parsed = try parseParams(jsonrpc.eth.GetBlockByHash.Params, temp_allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetBlockByHash(temp_allocator, &block_query_context, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getTransactionReceipt")) {
            const parsed = try parseParams(jsonrpc.eth.GetTransactionReceipt.Params, temp_allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetTransactionReceipt(temp_allocator, &block_query_context, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getBlockReceipts")) {
            const parsed = try parseParams(jsonrpc.eth.GetBlockReceipts.Params, temp_allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetBlockReceipts(temp_allocator, &block_query_context, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getLogs")) {
            const parsed = try parseParams(jsonrpc.eth.GetLogs.Params, temp_allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetLogs(temp_allocator, &block_query_context, parsed);
            return try toJsonValue(allocator, result);
        }
        if (std.mem.eql(u8, method_name, "eth_getTransactionByHash")) {
            const parsed = try parseParams(jsonrpc.eth.GetTransactionByHash.Params, temp_allocator, params);
            var block_query_context = makeBlockQueryContext(self);
            const result = try block_query_handlers.handleGetTransactionByHash(temp_allocator, &block_query_context, parsed);
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
            const snapshot_id = parseHexU64String(switch (result) {
                .string => |snapshot_id_string| snapshot_id_string,
                else => return error.InvalidParams,
            }) orelse return error.InvalidParams;
            var runtime_snapshot = try self.captureRuntimeSnapshot(allocator);
            errdefer runtime_snapshot.deinit(allocator);
            try self.runtime_snapshots.put(snapshot_id, runtime_snapshot);
            return result;
        }
        if (std.mem.eql(u8, method_name, "evm_revert")) {
            const snapshot_id = parseFirstU64(params) orelse return error.InvalidParams;
            if (!self.dev_runtime.snapshots.contains(snapshot_id)) {
                return .{ .bool = false };
            }
            const result = try dev_handlers.handleEvmRevert(
                allocator,
                &self.dev_runtime,
                &self.node_runtime.state,
                &self.node_runtime.blockchain,
                params,
            );
            if (result.bool) {
                const snapshot = self.runtime_snapshots.getPtr(snapshot_id) orelse return error.InvalidParams;
                self.restoreRuntimeSnapshot(allocator, snapshot);
                try self.discardRuntimeSnapshotsFrom(allocator, snapshot_id);
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
        if (std.mem.eql(u8, method_name, "hardhat_setAutomine") or std.mem.eql(u8, method_name, "evm_setAutomine") or std.mem.eql(u8, method_name, "anvil_setAutomine")) {
            const enabled = parseFirstBool(params) orelse return error.InvalidParams;
            self.node_runtime.setMiningConfig(if (enabled) .auto else .manual);
            self.last_interval_mine_ns = null;
            return .{ .bool = true };
        }
        if (std.mem.eql(u8, method_name, "hardhat_setIntervalMining") or std.mem.eql(u8, method_name, "evm_setIntervalMining") or std.mem.eql(u8, method_name, "anvil_setIntervalMining")) {
            const interval_millis = parseFirstU64(params) orelse 0;
            if (interval_millis == 0) {
                self.node_runtime.setMiningConfig(.manual);
                self.last_interval_mine_ns = null;
                return .{ .bool = true };
            }

            const interval_seconds = @max(@as(u64, 1), (interval_millis + 999) / 1000);
            self.node_runtime.setMiningConfig(.{ .interval = .{ .block_time = interval_seconds } });
            self.last_interval_mine_ns = std.time.nanoTimestamp();
            return .{ .bool = true };
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
                    const parent_hash = self.node_runtime.head_block_hash;
                    const next_timestamp: u64 = self.node_runtime.next_block_timestamp_override orelse self.node_runtime.current_timestamp + 1;
                    const next_base_fee: u256 = self.node_runtime.next_block_base_fee_override orelse self.node_runtime.base_fee;
                    const next_block_number = self.node_runtime.head_block_number + 1;
                    const block_hash = syntheticBlockHash(next_block_number, next_timestamp);
                    self.node_runtime.head_block_number = next_block_number;
                    self.node_runtime.current_timestamp = next_timestamp;
                    self.node_runtime.base_fee = next_base_fee;
                    self.node_runtime.next_block_timestamp_override = null;
                    self.node_runtime.next_block_base_fee_override = null;
                    try self.node_runtime.recordMinedBlock(
                        allocator,
                        next_block_number,
                        block_hash,
                        parent_hash,
                        next_timestamp,
                        next_base_fee,
                    );
                }
            }
            return .{ .string = try allocator.dupe(u8, "0x0") };
        }
        if (std.mem.eql(u8, method_name, "eth_newFilter")) {
            const id = self.next_filter_id;
            self.next_filter_id += 1;
            const filter_json = try extractFilterJson(allocator, params);
            errdefer allocator.free(filter_json);
            try self.filters.put(id, .{
                .kind = .log,
                .last_block = self.node_runtime.head_block_number,
                .filter_json = filter_json,
            });
            return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{id}) };
        }
        if (std.mem.eql(u8, method_name, "eth_newBlockFilter")) {
            const id = self.next_filter_id;
            self.next_filter_id += 1;
            try self.filters.put(id, .{
                .kind = .block,
                .last_block = self.node_runtime.head_block_number,
                .filter_json = null,
                .event_cursor = self.node_runtime.mined_block_events.items.len,
            });
            return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{id}) };
        }
        if (std.mem.eql(u8, method_name, "eth_newPendingTransactionFilter")) {
            const id = self.next_filter_id;
            self.next_filter_id += 1;
            try self.filters.put(id, .{
                .kind = .pending_transaction,
                .last_block = self.node_runtime.head_block_number,
                .filter_json = null,
                .event_cursor = self.node_runtime.pending_tx_events.items.len,
            });
            return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{id}) };
        }
        if (std.mem.eql(u8, method_name, "eth_getFilterChanges")) {
            return try self.handleGetFilterChanges(allocator, params);
        }
        if (std.mem.eql(u8, method_name, "eth_getFilterLogs")) {
            return try self.handleGetFilterLogs(allocator, params);
        }
        if (std.mem.eql(u8, method_name, "eth_uninstallFilter")) {
            const id = parseFirstU64(params) orelse return error.InvalidParams;
            if (self.filters.fetchRemove(id)) |entry| {
                if (entry.value.filter_json) |json| {
                    allocator.free(json);
                }
                return .{ .bool = true };
            }
            return .{ .bool = false };
        }
        if (std.mem.eql(u8, method_name, "eth_subscribe")) {
            const subscription_kind = parseSubscriptionKind(params) orelse return error.InvalidParams;
            const filter_json = if (subscription_kind == .logs)
                try extractSubscriptionFilterJson(allocator, params)
            else
                null;
            errdefer if (filter_json) |json| allocator.free(json);

            const id = self.next_filter_id;
            self.next_filter_id += 1;
            try self.filters.put(id, .{
                .kind = .subscription,
                .last_block = self.node_runtime.head_block_number,
                .filter_json = filter_json,
                .subscription_kind = subscription_kind,
                .event_cursor = switch (subscription_kind) {
                    .new_heads => self.node_runtime.mined_block_events.items.len,
                    .new_pending_transactions => self.node_runtime.pending_tx_events.items.len,
                    .logs, .syncing => 0,
                },
            });
            return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{id}) };
        }
        if (std.mem.eql(u8, method_name, "eth_unsubscribe")) {
            const id = parseFirstU64(params) orelse return error.InvalidParams;
            if (self.filters.fetchRemove(id)) |entry| {
                if (entry.value.filter_json) |json| {
                    allocator.free(json);
                }
                return .{ .bool = true };
            }
            return .{ .bool = false };
        }
        if (std.mem.eql(u8, method_name, "debug_traceCall")) {
            return try self.traceCall(allocator, params);
        }
        if (std.mem.eql(u8, method_name, "debug_traceTransaction")) {
            return try self.traceTransaction(allocator, params);
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

        var host_fork_resolver_context = HostForkResolverContext{
            .allocator = allocator,
            .node_runtime = &self.node_runtime,
        };
        var adapter = host_adapter.HostAdapter{
            .state = &self.node_runtime.state,
            .fork_resolver = .{
                .context = @ptrCast(&host_fork_resolver_context),
                .resolve = resolveHostForkPending,
            },
        };
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

        var host_fork_resolver_context = HostForkResolverContext{
            .allocator = allocator,
            .node_runtime = &self.node_runtime,
        };
        var adapter = host_adapter.HostAdapter{
            .state = &self.node_runtime.state,
            .fork_resolver = .{
                .context = @ptrCast(&host_fork_resolver_context),
                .resolve = resolveHostForkPending,
            },
        };
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

    fn traceCall(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        params: ?std.json.Value,
    ) !std.json.Value {
        const call = parseCallRequest(
            allocator,
            params,
            self.node_runtime.coinbase,
            self.node_runtime.block_gas_limit,
            self.node_runtime.gas_price,
        ) catch return error.InvalidParams;
        defer allocator.free(call.data);

        const trace_config = parseTraceCallConfig(params);
        const trace = try self.runTraceExecution(allocator, call, trace_config);
        defer allocator.free(trace.output);
        return try buildTraceResult(allocator, trace.gas_used, trace.failed, trace.output, trace.struct_logs);
    }

    fn traceTransaction(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        params: ?std.json.Value,
    ) !std.json.Value {
        const tx_hash = parseFirstHash(params) orelse return error.InvalidParams;
        const record = self.node_runtime.getTransactionRecord(tx_hash) orelse return error.InvalidParams;
        const decoded = primitives.Transaction.decodeRawTransaction(allocator, record.raw) catch return error.InvalidParams;
        defer primitives.Transaction.deinitDecodedTransaction(allocator, decoded);

        const call: CallRequest = switch (decoded) {
            .legacy => |tx| .{
                .from = record.sender,
                .to = tx.to,
                .gas = tx.gas_limit,
                .gas_price = tx.gas_price,
                .value = tx.value,
                .nonce = tx.nonce,
                .data = try allocator.dupe(u8, tx.data),
            },
            .eip2930 => |tx| .{
                .from = record.sender,
                .to = tx.to,
                .gas = tx.gas_limit,
                .gas_price = tx.gas_price,
                .value = tx.value,
                .nonce = tx.nonce,
                .data = try allocator.dupe(u8, tx.data),
            },
            .eip1559 => |tx| .{
                .from = record.sender,
                .to = tx.to,
                .gas = tx.gas_limit,
                .gas_price = tx.max_fee_per_gas,
                .value = tx.value,
                .nonce = tx.nonce,
                .data = try allocator.dupe(u8, tx.data),
            },
            .eip4844 => |tx| .{
                .from = record.sender,
                .to = tx.to,
                .gas = tx.gas_limit,
                .gas_price = tx.max_fee_per_gas,
                .value = tx.value,
                .nonce = tx.nonce,
                .data = try allocator.dupe(u8, tx.data),
            },
            .eip7702 => |tx| .{
                .from = record.sender,
                .to = tx.to,
                .gas = tx.gas_limit,
                .gas_price = tx.max_fee_per_gas,
                .value = tx.value,
                .nonce = tx.nonce,
                .data = try allocator.dupe(u8, tx.data),
            },
        };
        defer allocator.free(call.data);

        const trace_config = parseTraceTransactionConfig(params);
        const trace = try self.runTraceExecution(allocator, call, trace_config);
        defer allocator.free(trace.output);
        return try buildTraceResult(allocator, trace.gas_used, trace.failed, trace.output, trace.struct_logs);
    }

    fn runTraceExecution(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        call: CallRequest,
        trace_config: primitives.TraceConfig,
    ) !TraceExecutionResult {
        try self.node_runtime.state.checkpoint();
        defer self.node_runtime.state.revert();

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

        var host_fork_resolver_context = HostForkResolverContext{
            .allocator = allocator,
            .node_runtime = &self.node_runtime,
        };
        var adapter = host_adapter.HostAdapter{
            .state = &self.node_runtime.state,
            .fork_resolver = .{
                .context = @ptrCast(&host_fork_resolver_context),
                .resolve = resolveHostForkPending,
            },
        };
        const host_iface = adapter.hostInterface();
        const EvmType = guillotine_mini.Evm(.{});
        var evm: EvmType = undefined;
        evm.init(allocator, host_iface, null, block_ctx, null) catch return error.InvalidParams;
        defer evm.deinit();
        evm.initTransactionState(null) catch return error.InvalidParams;

        var tracer = guillotine_mini.Tracer.init(allocator);
        defer tracer.deinit();
        tracer.config = trace_config;
        tracer.enable();
        evm.setTracer(&tracer);

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

        const struct_logs = try traceEntriesToStructLogs(allocator, tracer.entries.items, trace_config);
        return .{
            .gas_used = gas_limit - result.gas_left,
            .failed = !result.success,
            .output = try allocator.dupe(u8, result.output),
            .struct_logs = struct_logs,
        };
    }

    fn handleGetFilterChanges(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        params: ?std.json.Value,
    ) !std.json.Value {
        const id = parseFirstU64(params) orelse return error.InvalidParams;
        const state = self.filters.getPtr(id) orelse return error.FilterNotFound;

        switch (state.kind) {
            .block => {
                var result_array = std.json.Array.init(allocator);
                var index = state.event_cursor;
                while (index < self.node_runtime.mined_block_events.items.len) : (index += 1) {
                    const event = self.node_runtime.mined_block_events.items[index];
                    try result_array.append(.{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{event.hash}) });
                }
                state.event_cursor = self.node_runtime.mined_block_events.items.len;
                state.last_block = self.node_runtime.head_block_number;
                return .{ .array = result_array };
            },
            .log => {
                if (self.node_runtime.head_block_number <= state.last_block) {
                    return .{ .array = std.json.Array.init(allocator) };
                }
                const from_block = state.last_block + 1;
                const logs_value = try self.queryFilterLogs(allocator, state, from_block, self.node_runtime.head_block_number);
                state.last_block = self.node_runtime.head_block_number;
                return logs_value;
            },
            .pending_transaction => {
                var result_array = std.json.Array.init(allocator);
                var index = state.event_cursor;
                while (index < self.node_runtime.pending_tx_events.items.len) : (index += 1) {
                    const hash = self.node_runtime.pending_tx_events.items[index];
                    try result_array.append(.{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{hash}) });
                }
                state.event_cursor = self.node_runtime.pending_tx_events.items.len;
                return .{ .array = result_array };
            },
            .subscription => {
                return .{ .array = std.json.Array.init(allocator) };
            },
        }
    }

    fn handleGetFilterLogs(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        params: ?std.json.Value,
    ) !std.json.Value {
        const id = parseFirstU64(params) orelse return error.InvalidParams;
        const state = self.filters.getPtr(id) orelse return error.FilterNotFound;
        if (state.kind != .log) {
            return .{ .array = std.json.Array.init(allocator) };
        }
        return try self.queryFilterLogs(allocator, state, 0, self.node_runtime.head_block_number);
    }

    fn queryFilterLogs(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        state: *const FilterState,
        from_block: u64,
        to_block: u64,
    ) !std.json.Value {
        var filter = try parseStoredFilter(allocator, state.filter_json);
        filter.fromBlock = .{ .value = .{ .integer = @intCast(from_block) } };
        filter.toBlock = .{ .value = .{ .integer = @intCast(to_block) } };

        var block_query_context = makeBlockQueryContext(self);
        const logs_result = try block_query_handlers.handleGetLogs(
            allocator,
            &block_query_context,
            .{ .filter = filter },
        );
        return try toJsonValue(allocator, logs_result.logs);
    }

    pub fn collectSubscriptionMessages(self: *NodeHandler, allocator: std.mem.Allocator) ![][]u8 {
        var messages = std.ArrayList([]u8).empty;
        errdefer {
            for (messages.items) |message| {
                allocator.free(message);
            }
            messages.deinit(allocator);
        }

        var filter_it = self.filters.iterator();
        while (filter_it.next()) |entry| {
            const id = entry.key_ptr.*;
            const state = entry.value_ptr;
            if (state.kind != .subscription) continue;
            const subscription_kind = state.subscription_kind orelse continue;

            switch (subscription_kind) {
                .new_heads => {
                    var arena_state = std.heap.ArenaAllocator.init(allocator);
                    defer arena_state.deinit();
                    const arena = arena_state.allocator();

                    var index = state.event_cursor;
                    while (index < self.node_runtime.mined_block_events.items.len) : (index += 1) {
                        const event = self.node_runtime.mined_block_events.items[index];
                        const header = try buildNewHeadResult(arena, &self.node_runtime, event);
                        const message = try buildSubscriptionMessage(allocator, id, header);
                        try messages.append(allocator, message);
                    }
                    state.event_cursor = self.node_runtime.mined_block_events.items.len;
                    state.last_block = self.node_runtime.head_block_number;
                },
                .logs => {
                    if (self.node_runtime.head_block_number > state.last_block) {
                        var arena_state = std.heap.ArenaAllocator.init(allocator);
                        defer arena_state.deinit();
                        const arena = arena_state.allocator();

                        const from_block = state.last_block + 1;
                        const to_block = self.node_runtime.head_block_number;
                        const logs_value = try self.queryFilterLogs(arena, state, from_block, to_block);
                        const log_items = switch (logs_value) {
                            .array => |array| array.items,
                            else => &[_]std.json.Value{},
                        };
                        for (log_items) |log_item| {
                            const message = try buildSubscriptionMessage(allocator, id, log_item);
                            try messages.append(allocator, message);
                        }
                        state.last_block = self.node_runtime.head_block_number;
                    }
                },
                .new_pending_transactions => {
                    var index = state.event_cursor;
                    while (index < self.node_runtime.pending_tx_events.items.len) : (index += 1) {
                        const tx_hash = self.node_runtime.pending_tx_events.items[index];
                        var arena_state = std.heap.ArenaAllocator.init(allocator);
                        defer arena_state.deinit();
                        const arena = arena_state.allocator();
                        const result_value: std.json.Value = .{
                            .string = try std.fmt.allocPrint(arena, "0x{x}", .{tx_hash}),
                        };
                        const message = try buildSubscriptionMessage(allocator, id, result_value);
                        try messages.append(allocator, message);
                    }
                    state.event_cursor = self.node_runtime.pending_tx_events.items.len;
                },
                .syncing => {},
            }
        }

        return messages.toOwnedSlice(allocator);
    }

    pub fn maybeMineInterval(self: *NodeHandler, allocator: std.mem.Allocator) !void {
        if (self.node_runtime.mining_mode != .interval or self.node_runtime.interval_seconds == 0) {
            self.last_interval_mine_ns = null;
            return;
        }
        if (self.node_runtime.pool.pendingCount() == 0) {
            return;
        }

        const now = std.time.nanoTimestamp();
        if (self.last_interval_mine_ns == null) {
            self.last_interval_mine_ns = now;
            return;
        }

        const interval_ns: i128 = @as(i128, @intCast(self.node_runtime.interval_seconds)) * std.time.ns_per_s;
        if (now - self.last_interval_mine_ns.? >= interval_ns) {
            try tx_submission.minePendingTransactions(allocator, &self.node_runtime);
            self.last_interval_mine_ns = now;
        }
    }

    fn captureRuntimeSnapshot(self: *NodeHandler, allocator: std.mem.Allocator) !RuntimeSnapshot {
        var tx_index_copy = try copyTxIndex(allocator, &self.node_runtime.tx_index);
        errdefer {
            var tx_it = tx_index_copy.valueIterator();
            while (tx_it.next()) |record| {
                allocator.free(record.raw);
            }
            tx_index_copy.deinit();
        }

        var pool_copy = try copyTxPool(allocator, &self.node_runtime.pool);
        errdefer pool_copy.deinit(allocator);

        var pending_tx_events_copy = std.ArrayList([32]u8).empty;
        errdefer pending_tx_events_copy.deinit(allocator);
        try pending_tx_events_copy.appendSlice(allocator, self.node_runtime.pending_tx_events.items);

        var mined_block_events_copy = std.ArrayList(runtime.BlockEvent).empty;
        errdefer mined_block_events_copy.deinit(allocator);
        try mined_block_events_copy.appendSlice(allocator, self.node_runtime.mined_block_events.items);

        var impersonated_accounts_copy = try copyAddressSet(allocator, &self.node_runtime.impersonated_accounts);
        errdefer impersonated_accounts_copy.deinit();

        return .{
            .coinbase = self.node_runtime.coinbase,
            .block_gas_limit = self.node_runtime.block_gas_limit,
            .head_block_number = self.node_runtime.head_block_number,
            .head_block_hash = self.node_runtime.head_block_hash,
            .current_timestamp = self.node_runtime.current_timestamp,
            .base_fee = self.node_runtime.base_fee,
            .prev_randao = self.node_runtime.prev_randao,
            .next_block_base_fee_override = self.node_runtime.next_block_base_fee_override,
            .next_block_timestamp_override = self.node_runtime.next_block_timestamp_override,
            .mining_mode = self.node_runtime.mining_mode,
            .interval_seconds = self.node_runtime.interval_seconds,
            .tx_index = tx_index_copy,
            .pool = pool_copy,
            .pending_tx_events = pending_tx_events_copy,
            .mined_block_events = mined_block_events_copy,
            .impersonated_accounts = impersonated_accounts_copy,
        };
    }

    fn restoreRuntimeSnapshot(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        snapshot: *RuntimeSnapshot,
    ) void {
        var tx_it = self.node_runtime.tx_index.valueIterator();
        while (tx_it.next()) |record| {
            allocator.free(record.raw);
        }
        self.node_runtime.tx_index.deinit();
        self.node_runtime.pool.deinit(allocator);
        self.node_runtime.pending_tx_events.deinit(allocator);
        self.node_runtime.mined_block_events.deinit(allocator);
        self.node_runtime.impersonated_accounts.deinit();

        self.node_runtime.coinbase = snapshot.coinbase;
        self.node_runtime.block_gas_limit = snapshot.block_gas_limit;
        self.node_runtime.head_block_number = snapshot.head_block_number;
        self.node_runtime.head_block_hash = snapshot.head_block_hash;
        self.node_runtime.current_timestamp = snapshot.current_timestamp;
        self.node_runtime.base_fee = snapshot.base_fee;
        self.node_runtime.prev_randao = snapshot.prev_randao;
        self.node_runtime.next_block_base_fee_override = snapshot.next_block_base_fee_override;
        self.node_runtime.next_block_timestamp_override = snapshot.next_block_timestamp_override;
        self.node_runtime.mining_mode = snapshot.mining_mode;
        self.node_runtime.interval_seconds = snapshot.interval_seconds;
        self.node_runtime.tx_index = snapshot.tx_index;
        self.node_runtime.pool = snapshot.pool;
        self.node_runtime.pending_tx_events = snapshot.pending_tx_events;
        self.node_runtime.mined_block_events = snapshot.mined_block_events;
        self.node_runtime.impersonated_accounts = snapshot.impersonated_accounts;

        snapshot.tx_index = std.AutoHashMap([32]u8, runtime.TransactionRecord).init(allocator);
        snapshot.pool = txpool.TxPool.init(allocator);
        snapshot.pending_tx_events = std.ArrayList([32]u8).empty;
        snapshot.mined_block_events = std.ArrayList(runtime.BlockEvent).empty;
        snapshot.impersonated_accounts = std.AutoHashMap(primitives.Address, void).init(allocator);
        self.last_interval_mine_ns = null;
    }

    fn discardRuntimeSnapshotsFrom(
        self: *NodeHandler,
        allocator: std.mem.Allocator,
        snapshot_id: u64,
    ) !void {
        var snapshot_ids = std.ArrayList(u64).empty;
        defer snapshot_ids.deinit(allocator);

        var snapshot_it = self.runtime_snapshots.iterator();
        while (snapshot_it.next()) |entry| {
            if (entry.key_ptr.* >= snapshot_id) {
                try snapshot_ids.append(allocator, entry.key_ptr.*);
            }
        }

        for (snapshot_ids.items) |id| {
            if (self.runtime_snapshots.fetchRemove(id)) |entry| {
                var removed_snapshot = entry.value;
                removed_snapshot.deinit(allocator);
            }
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
    defer parsed.deinit();

    return try cloneJsonValue(allocator, parsed.value);
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |array| blk: {
            var copied = std.json.Array.init(allocator);
            errdefer copied.deinit();
            for (array.items) |item| {
                try copied.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = copied };
        },
        .object => |object| blk: {
            var copied = std.json.ObjectMap.init(allocator);
            errdefer copied.deinit();
            var object_it = object.iterator();
            while (object_it.next()) |entry| {
                const owned_key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(owned_key);
                const copied_value = try cloneJsonValue(allocator, entry.value_ptr.*);
                try copied.put(owned_key, copied_value);
            }
            break :blk .{ .object = copied };
        },
    };
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

fn parseSubscriptionKind(params: ?std.json.Value) ?SubscriptionKind {
    const array = switch (params orelse return null) {
        .array => |arr| arr.items,
        else => return null,
    };
    if (array.len == 0) return null;
    const name = switch (array[0]) {
        .string => |string| string,
        else => return null,
    };

    if (std.mem.eql(u8, name, "newHeads")) return .new_heads;
    if (std.mem.eql(u8, name, "logs")) return .logs;
    if (std.mem.eql(u8, name, "newPendingTransactions")) return .new_pending_transactions;
    if (std.mem.eql(u8, name, "syncing")) return .syncing;
    return null;
}

fn extractSubscriptionFilterJson(allocator: std.mem.Allocator, params: ?std.json.Value) ![]u8 {
    const array = switch (params orelse return allocator.dupe(u8, "{}")) {
        .array => |arr| arr.items,
        else => return allocator.dupe(u8, "{}"),
    };
    if (array.len < 2) return allocator.dupe(u8, "{}");

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(array[1], .{}, &writer.writer);
    return writer.toOwnedSlice();
}

fn extractFilterJson(allocator: std.mem.Allocator, params: ?std.json.Value) ![]u8 {
    const array = switch (params orelse return allocator.dupe(u8, "{}")) {
        .array => |arr| arr.items,
        else => return allocator.dupe(u8, "{}"),
    };
    if (array.len == 0) return allocator.dupe(u8, "{}");

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(array[0], .{}, &writer.writer);
    return writer.toOwnedSlice();
}

fn buildSubscriptionMessage(
    allocator: std.mem.Allocator,
    subscription_id: u64,
    result: std.json.Value,
) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    try writer.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"eth_subscription\",\"params\":{\"subscription\":\"");
    try writer.writer.print("0x{x}", .{subscription_id});
    try writer.writer.writeAll("\",\"result\":");
    try std.json.Stringify.value(result, .{}, &writer.writer);
    try writer.writer.writeAll("}}");

    return writer.toOwnedSlice();
}

fn buildNewHeadResult(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    event: runtime.BlockEvent,
) !std.json.Value {
    var object = std.json.ObjectMap.init(allocator);
    try object.put("number", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{event.number}) });
    try object.put("hash", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{event.hash}) });
    try object.put("parentHash", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{event.parent_hash}) });
    try object.put("timestamp", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{event.timestamp}) });
    try object.put("miner", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{rt.coinbase.bytes}) });
    try object.put("gasLimit", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{rt.block_gas_limit}) });
    try object.put("gasUsed", .{ .string = "0x0" });
    try object.put("baseFeePerGas", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{event.base_fee}) });
    return .{ .object = object };
}

fn parseStoredFilter(
    allocator: std.mem.Allocator,
    filter_json: ?[]u8,
) !jsonrpc.types.Filter {
    if (filter_json == null) return jsonrpc.types.Filter{};

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, filter_json.?, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    return std.json.innerParseFromValue(jsonrpc.types.Filter, allocator, parsed.value, .{}) catch jsonrpc.types.Filter{};
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

fn parseFirstHash(params: ?std.json.Value) ?[32]u8 {
    const array = switch (params orelse return null) {
        .array => |arr| arr.items,
        else => return null,
    };
    if (array.len == 0) return null;
    const value = switch (array[0]) {
        .string => |string| string,
        else => return null,
    };
    return primitives.Hex.hexToBytesFixed(32, value) catch null;
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

fn parseFirstBool(params: ?std.json.Value) ?bool {
    const array = switch (params orelse return null) {
        .array => |arr| arr.items,
        else => return null,
    };
    if (array.len == 0) return null;
    return switch (array[0]) {
        .bool => |value| value,
        else => null,
    };
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

fn parseHexU64String(value: []const u8) ?u64 {
    var hex = value;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
        hex = hex[2..];
    }
    if (hex.len == 0) return 0;
    return std.fmt.parseInt(u64, hex, 16) catch null;
}

fn copyTxIndex(
    allocator: std.mem.Allocator,
    source: *const std.AutoHashMap([32]u8, runtime.TransactionRecord),
) !std.AutoHashMap([32]u8, runtime.TransactionRecord) {
    var copy = std.AutoHashMap([32]u8, runtime.TransactionRecord).init(allocator);
    errdefer {
        var copy_it = copy.valueIterator();
        while (copy_it.next()) |record| {
            allocator.free(record.raw);
        }
        copy.deinit();
    }

    var source_it = source.iterator();
    while (source_it.next()) |entry| {
        const copied_raw = try allocator.dupe(u8, entry.value_ptr.raw);
        try copy.put(entry.key_ptr.*, .{
            .sender = entry.value_ptr.sender,
            .raw = copied_raw,
            .block_hash = entry.value_ptr.block_hash,
            .block_number = entry.value_ptr.block_number,
            .block_timestamp = entry.value_ptr.block_timestamp,
            .transaction_index = entry.value_ptr.transaction_index,
        });
    }
    return copy;
}

fn copyTxPool(
    allocator: std.mem.Allocator,
    source: *const txpool.TxPool,
) !txpool.TxPool {
    var copy = txpool.TxPool.init(allocator);
    errdefer copy.deinit(allocator);

    var nonce_it = source.nonce_state.iterator();
    while (nonce_it.next()) |entry| {
        try copy.nonce_state.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var hash_it = source.hash_index.iterator();
    while (hash_it.next()) |entry| {
        try copy.hash_index.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var sender_it = source.sender_queues.iterator();
    while (sender_it.next()) |entry| {
        var queue_copy = std.ArrayListUnmanaged(txpool.TxPool.PooledTransaction){};
        errdefer queue_copy.deinit(allocator);
        try queue_copy.appendSlice(allocator, entry.value_ptr.items);
        try copy.sender_queues.put(entry.key_ptr.*, queue_copy);
    }

    return copy;
}

fn copyAddressSet(
    allocator: std.mem.Allocator,
    source: *const std.AutoHashMap(primitives.Address, void),
) !std.AutoHashMap(primitives.Address, void) {
    var copy = std.AutoHashMap(primitives.Address, void).init(allocator);
    errdefer copy.deinit();

    var source_it = source.iterator();
    while (source_it.next()) |entry| {
        try copy.put(entry.key_ptr.*, {});
    }
    return copy;
}

fn buildTraceResult(
    allocator: std.mem.Allocator,
    gas_used: u64,
    failed: bool,
    output: []const u8,
    struct_logs: std.json.Array,
) !std.json.Value {
    var object = std.json.ObjectMap.init(allocator);
    try object.put("gas", .{ .integer = @intCast(gas_used) });
    try object.put("failed", .{ .bool = failed });
    try object.put("returnValue", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{output}) });
    try object.put("structLogs", .{ .array = struct_logs });
    return .{ .object = object };
}

fn parseTraceCallConfig(params: ?std.json.Value) primitives.TraceConfig {
    const array = switch (params orelse return primitives.TraceConfig.from()) {
        .array => |arr| arr.items,
        else => return primitives.TraceConfig.from(),
    };
    if (array.len < 3) return primitives.TraceConfig.from();
    return parseTraceConfigFromValue(array[2]);
}

fn parseTraceTransactionConfig(params: ?std.json.Value) primitives.TraceConfig {
    const array = switch (params orelse return primitives.TraceConfig.from()) {
        .array => |arr| arr.items,
        else => return primitives.TraceConfig.from(),
    };
    if (array.len < 2) return primitives.TraceConfig.from();
    return parseTraceConfigFromValue(array[1]);
}

fn parseTraceConfigFromValue(value: std.json.Value) primitives.TraceConfig {
    const object = switch (value) {
        .object => |obj| obj,
        else => return primitives.TraceConfig.from(),
    };

    var config = primitives.TraceConfig.from();
    if (object.get("disableStorage")) |disable_storage| {
        if (disable_storage == .bool) {
            config.disable_storage = disable_storage.bool;
        }
    }
    if (object.get("disableStack")) |disable_stack| {
        if (disable_stack == .bool) {
            config.disable_stack = disable_stack.bool;
        }
    }
    if (object.get("disableMemory")) |disable_memory| {
        if (disable_memory == .bool) {
            config.disable_memory = disable_memory.bool;
        }
    }
    if (object.get("enableMemory")) |enable_memory| {
        if (enable_memory == .bool) {
            config.enable_memory = enable_memory.bool;
        }
    }
    if (object.get("enableReturnData")) |enable_return_data| {
        if (enable_return_data == .bool) {
            config.enable_return_data = enable_return_data.bool;
        }
    }
    if (object.get("tracer")) |tracer| {
        if (tracer == .string) {
            config.tracer = tracer.string;
        }
    }
    if (object.get("timeout")) |timeout| {
        if (timeout == .string) {
            config.timeout = timeout.string;
        }
    }
    return config;
}

fn traceEntriesToStructLogs(
    allocator: std.mem.Allocator,
    entries: []const guillotine_mini.TraceEntry,
    trace_config: primitives.TraceConfig,
) !std.json.Array {
    var struct_logs = std.json.Array.init(allocator);
    for (entries) |entry| {
        var object = std.json.ObjectMap.init(allocator);
        try object.put("pc", .{ .integer = @intCast(entry.pc) });
        try object.put("op", .{ .string = try allocator.dupe(u8, entry.opName) });
        try object.put("gas", .{ .integer = @intCast(entry.gas) });
        try object.put("gasCost", .{ .integer = @intCast(entry.gasCost) });
        try object.put("depth", .{ .integer = @intCast(entry.depth) });
        try object.put("memSize", .{ .integer = @intCast(entry.memSize) });

        if (trace_config.tracksStack()) {
            var stack_array = std.json.Array.init(allocator);
            for (entry.stack) |stack_item| {
                try stack_array.append(.{
                    .string = try std.fmt.allocPrint(allocator, "{x:0>64}", .{stack_item}),
                });
            }
            try object.put("stack", .{ .array = stack_array });
        }

        if (trace_config.tracksMemory()) {
            if (entry.memory) |memory| {
                const memory_words = try memoryToWords(allocator, memory);
                try object.put("memory", .{ .array = memory_words });
            } else {
                try object.put("memory", .{ .array = std.json.Array.init(allocator) });
            }
        }

        if (trace_config.tracksStorage()) {
            try object.put("storage", .{ .object = std.json.ObjectMap.init(allocator) });
        }

        if (entry.error_msg) |error_msg| {
            try object.put("error", .{ .string = try allocator.dupe(u8, error_msg) });
        }

        try struct_logs.append(.{ .object = object });
    }
    return struct_logs;
}

fn memoryToWords(allocator: std.mem.Allocator, memory: []const u8) !std.json.Array {
    var words = std.json.Array.init(allocator);
    if (memory.len == 0) return words;

    var index: usize = 0;
    while (index < memory.len) : (index += 32) {
        var word: [32]u8 = [_]u8{0} ** 32;
        const copy_len = @min(@as(usize, 32), memory.len - index);
        @memcpy(word[0..copy_len], memory[index .. index + copy_len]);
        try words.append(.{ .string = try std.fmt.allocPrint(allocator, "{x}", .{word}) });
    }
    return words;
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
