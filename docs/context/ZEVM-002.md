# ZEVM-002: Research for evm_mine RPC Handler

**Ticket**: ZEVM-002  
**Title**: Implement evm_mine RPC handler  
**Category**: cat-6-mining  
**Status**: Research Complete  

## Overview

Implement `evm_mine(blocks?: number, interval?: number) -> null` RPC method. Mines N blocks (default 1) with optional interval seconds between block timestamps.

---

## Reference Implementations

### 1. TEVM (TypeScript) - Primary Reference

**Path**: `../tevm-monorepo/packages/actions/src/Mine/`

Key files:
- `mineHandler.js` - Main mining logic (170 lines)
- `MineParams.ts` - Parameter types
- `processTx.js` - Transaction processing during mining

**MineParams Interface**:
```typescript
type MineParams = {
  blockCount?: number;  // Default: 1
  interval?: number;    // Default: 1 (seconds between blocks)
  tx?: Hex;            // Optional: specific tx hash to mine
}
```

**Key Implementation Details**:
1. Get parent block from blockchain
2. Calculate timestamp: `max(now, parent_timestamp) + (count > 0 ? interval : 0)`
3. Build block with `vm.buildBlock()`
4. Add transactions from pool (ordered by price and nonce)
5. State manager checkpoint → commit
6. Save receipts and put block to blockchain
7. Remove mined txs from pool

**Timestamp Logic**:
```javascript
let timestamp = Math.max(Math.floor(Date.now() / 1000), Number(parentBlock.header.timestamp))
timestamp = count === 0 ? timestamp : timestamp + interval
```

---

### 2. EDR (Rust) - Secondary Reference

**Path**: `edr/crates/edr_provider/src/requests/methods.rs`

**Method Definition** (lines 1474-1503):
```rust
/// # `evm_mine`
/// 
/// Mines a single block, including as many transactions from the
/// transaction pool as possible.
///
/// ## Result
/// `String` - Always returns `"0"`.
#[serde(rename = "evm_mine")]
EvmMine(
    /// `QUANTITY` - Optional timestamp for the mined block. If not
    /// provided, the block timestamp is determined automatically.
    Option<Timestamp>,
),
```

**Handler**: `eth::handle_mine_request(data, timestamp)` in `provider.rs`

**Key Difference**: EDR's evm_mine only accepts an optional timestamp, not block count or interval.

---

### 3. Foundry Anvil (Rust) - Most Complete Reference

**Path**: `foundry/crates/anvil/core/src/eth/mod.rs`  
**API Implementation**: `foundry/crates/anvil/src/eth/api.rs`

**Method Definition** (lines 574-583):
```rust
/// Mine a single block
#[serde(rename = "evm_mine")]
EvmMine(#[serde(default)] Option<Params<Option<MineOptions>>>),

/// Mine a single block and return detailed data
#[serde(rename = "anvil_mine_detailed", alias = "evm_mine_detailed")]
EvmMineDetailed(#[serde(default)] Option<Params<Option<MineOptions>>>),
```

**MineOptions** (in alloy-rpc-types):
```rust
pub enum MineOptions {
    Timestamp(Option<u64>),
    Options { timestamp: Option<u64>, blocks: Option<u64> },
}
```

**Implementation Flow** in `api.rs`:
1. `evm_mine(opts)` → calls `do_evm_mine(opts)`
2. Parse blocks_to_mine (default: 1) and optional timestamp
3. If timestamp provided → call `evm_set_next_block_timestamp(timestamp)`
4. Loop: `for _ in 0..blocks_to_mine { this.mine_one().await; }`

**mine_one function** (api.rs):
```rust
pub async fn mine_one(&self) {
    let transactions = self.pool.ready_transactions().collect::<Vec<_>>();
    let outcome = self.backend.mine_block(transactions).await;
    trace!(target: "node", blocknumber = ?outcome.block_number, "mined block");
    self.pool.on_mined_block(outcome);
}
```

**Also implements**: `anvil_mine` / `hardhat_mine` (blocks, interval)
```rust
#[serde(rename = "anvil_mine", alias = "hardhat_mine")]
Mine(
    #[serde(default, deserialize_with = "deserialize_number_opt")]
    Option<U256>,  // blocks
    #[serde(default, deserialize_with = "deserialize_number_opt")]
    Option<U256>,  // interval seconds
),
```

---

## Upstream Dependencies (We Own These)

### voltaire (`../voltaire/packages/voltaire-zig/src/`)

**Blockchain** (`blockchain/Blockchain.zig`):
- `putBlock(block)` - Store mined block
- `setCanonicalHead(hash)` - Update chain head
- `getHeadBlockNumber()` - Get current tip
- `getBlockByNumber(number)` - Retrieve block

**StateManager** (`state-manager/StateManager.zig`):
- `checkpoint()` / `commit()` / `revert()` - State journaling
- `snapshot()` / `revertToSnapshot(id)` - Testing snapshots
- `getBalance()`, `setBalance()` - Account state

**BlockStore** (`blockchain/BlockStore.zig`):
- Local block storage with canonical chain tracking

### guillotine-mini (`../bench/guillotine-mini/`)

**Note**: Directory exists but no .zig files found. May need to add RPC dispatch/routing there.

---

## ZEVM Existing Code

### block_builder.zig (`src/block_builder.zig`)

Already implements block building:
```zig
pub const BlockResult = struct {
    receipts: []primitives.Receipt.Receipt,
    total_gas_used: u64,
    block_number: u64,
};

pub fn buildBlock(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    transactions: []const tx_processor.ExecutionTx,
    block_ctx: guillotine_mini.BlockContext,
) !BlockResult
```

**Key behaviors**:
- Invalid transactions (bad nonce, insufficient balance) are dropped
- Gas limit enforcement
- Receipt generation with cumulative gas

---

## evm_mine Specification

### JSON-RPC Interface

**Method**: `evm_mine`  
**Params**: `[blocks?, interval?]` (both optional)  
**Returns**: `null`

**Examples**:
```json
// Mine 1 block immediately
{"method": "evm_mine", "params": []}

// Mine 5 blocks
{"method": "evm_mine", "params": [5]}

// Mine 10 blocks with 60 seconds between each
{"method": "evm_mine", "params": [10, 60]}
```

### Behavior Requirements

1. **Blocks parameter**: Number of blocks to mine (default: 1)
2. **Interval parameter**: Seconds between block timestamps (default: 1)
3. **Timestamp calculation**:
   - First block: `max(current_time, parent_timestamp + 1)`
   - Subsequent blocks: `previous_timestamp + interval`
4. **Transactions**: Include all ready transactions from mempool
5. **State**: Commit state after each block
6. **Return**: Always returns `null`

### Integration Points

**Required Components**:
1. **Mempool** - Store pending transactions (not yet implemented)
2. **BlockBuilder** - Use existing `block_builder.zig`
3. **Blockchain** - Store mined blocks via `Blockchain.putBlock()`
4. **StateManager** - Commit state changes

**State Flow**:
1. Get pending transactions from mempool
2. For each block to mine:
   a. Calculate timestamp
   b. Build block via `block_builder.buildBlock()`
   c. Commit state via `StateManager.commit()`
   d. Store block via `Blockchain.putBlock()`
   e. Update canonical head via `Blockchain.setCanonicalHead()`

---

## Implementation Plan

### Files to Create/Modify

1. **New**: `src/rpc/evm_mine.zig` - Handler implementation
2. **Modify**: `src/root.zig` - Export new modules
3. **New**: `src/mempool.zig` - Transaction pool (if not in voltaire)

### Dependencies

From voltaire:
- `blockchain.Blockchain` - Block storage
- `state_manager.StateManager` - State management
- `primitives.Block`, `primitives.BlockHeader` - Block types

From guillotine-mini:
- `HostInterface`, `BlockContext` - EVM interface

### Testing Approach

Reference tests from:
- `edr/hardhat-tests/test/internal/hardhat-network/provider/modules/evm.ts`
- `foundry/crates/anvil/tests/it/anvil_api.rs`

Key test cases:
1. Mine single block with no transactions
2. Mine multiple blocks with interval
3. Mine block with pending transactions
4. Verify block timestamps are correct
5. Verify state is properly committed

---

## Related Methods

Future mining-related methods to implement:
- `hardhat_mine` / `anvil_mine` - Same as evm_mine but with different return
- `evm_setAutomine` - Enable/disable automining
- `evm_setIntervalMining` - Mine at fixed intervals
- `evm_increaseTime` - Fast-forward time
- `evm_setNextBlockTimestamp` - Set specific timestamp

---

## Research Sources Summary

| Source | Path | Key Finding |
|--------|------|-------------|
| TEVM Mine | `../tevm-monorepo/packages/actions/src/Mine/` | Complete mining implementation with interval support |
| EDR Methods | `edr/crates/edr_provider/src/requests/methods.rs` | RPC method definitions and serde |
| Foundry API | `foundry/crates/anvil/src/eth/api.rs` | `mine_one()` and `do_evm_mine()` implementation |
| Foundry Types | `foundry/crates/anvil/core/src/eth/mod.rs` | `MineOptions` enum and request parsing |
| voltaire Blockchain | `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig` | Block storage and chain management |
| voltaire StateManager | `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig` | State journaling and snapshots |
| ZEVM BlockBuilder | `src/block_builder.zig` | Existing block building logic |

---

## Open Questions

1. **Mempool location**: Should mempool be in zevm or added to voltaire?
2. **Timestamp source**: Use system time or allow manual time manipulation?
3. **Transaction ordering**: Price+nonce (standard) or FIFO?
4. **Error handling**: What errors should evm_mine return?

---

## Next Steps

1. Verify guillotine-mini has necessary RPC infrastructure
2. Check if voltaire has mempool implementation
3. Implement evm_mine handler in zevm
4. Add tests based on reference implementations
5. Run `zig build test` to verify
