const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const tx_processor = @import("tx_processor.zig");

pub const BlockResult = struct {
    receipts: []tx_processor.TxReceipt,
    total_gas_used: u64,
    block_number: u64,

    pub fn deinit(self: *BlockResult, allocator: std.mem.Allocator) void {
        for (self.receipts) |receipt| {
            receipt.deinit(allocator);
        }
        allocator.free(self.receipts);
    }
};

/// Executes a list of transactions sequentially and produces a block result.
///
/// Invalid transactions (bad nonce, insufficient balance) are dropped
/// entirely, matching Ethereum consensus behavior. Only transactions that
/// pass validation are included — even if the EVM execution reverts.
///
/// The caller is responsible for computing the state root after flushing
/// state to the accounts trie via Database.syncAccountToTrie.
pub fn buildBlock(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    transactions: []const tx_processor.ExecutionTx,
    block_ctx: guillotine_mini.BlockContext,
) !BlockResult {
    var receipts = std.array_list.Managed(tx_processor.TxReceipt).init(allocator);
    errdefer {
        for (receipts.items) |r| r.deinit(allocator);
        receipts.deinit();
    }

    var total_gas_used: u64 = 0;

    for (transactions) |item| {
        if (total_gas_used >= block_ctx.block_gas_limit) {
            break;
        }
        const remaining = block_ctx.block_gas_limit - total_gas_used;
        if (item.tx.gas_limit > remaining) {
            continue;
        }

        var receipt = tx_processor.processTransaction(
            allocator,
            sm,
            host_iface,
            item.caller,
            item.tx,
            block_ctx,
        ) catch |err| switch (err) {
            tx_processor.TxError.NonceMismatch,
            tx_processor.TxError.IntrinsicGasExceedsLimit,
            tx_processor.TxError.InsufficientBalance,
            => continue, // Invalid transaction — drop it (not included in block)
            else => return err,
        };

        const gas_used_u64 = std.math.cast(u64, receipt.gas_used) orelse return error.GasOverflow;
        total_gas_used += gas_used_u64;
        receipt.cumulative_gas_used = @as(u256, total_gas_used);
        receipt.transaction_index = @as(u32, @intCast(receipts.items.len));
        try receipts.append(receipt);
    }

    return BlockResult{
        .receipts = try receipts.toOwnedSlice(),
        .total_gas_used = total_gas_used,
        .block_number = block_ctx.block_number,
    };
}
