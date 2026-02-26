# Context: ZEVM-006 - Integrate automine with transaction submission

## Ticket
- **ID**: `ZEVM-006`
- **Category**: `cat-6-mining`
- **Goal**: After a transaction is submitted via `eth_sendRawTransaction` or `eth_sendTransaction`, if automine is enabled (`mining_config == .auto`), automatically call mine logic to mine a new block containing that transaction.
- **Reference**: `../tevm-monorepo/packages/actions/src/Call/handleAutomining.js`

---

## Prerequisites / Prior Art in ZEVM

| Ticket | What it adds | Status |
|--------|-------------|--------|
| ZEVM-001 | `MiningConfig` tagged union (`auto`, `manual`, `interval`) + `ZevmNode` struct with `mining_config` field | planned |
| ZEVM-002 | `evm_mine` RPC handler — block building from mempool, timestamp logic | planned |
| ZEVM-004 | `evm_setAutomine` RPC handler — sets `mining_config` to `.auto` or `.manual` | planned |
| ZEVM-003 | `eth_sendTransaction` + `eth_sendRawTransaction` handlers — put tx in mempool, return hash | not yet documented |

**ZEVM-006 sits after all of the above.** It wires the automine check into the send-tx pipeline.

---

## Current ZEVM State

- `src/main.zig` — only a banner entrypoint
- `src/root.zig` — exports execution/light-client modules; no RPC server, no node struct, no mempool
- `src/tx_processor.zig` — processes a single `LegacyTransaction` against `StateManager`; returns `Receipt`
- `src/block_builder.zig` — runs `processTransaction` in a loop over a slice of `ExecutionTx`; returns `BlockResult`
- `src/database/database.zig` — `Database` struct owns `StateManager`, trie, contracts, block hashes
- No `src/mining.zig`, `src/node.zig`, `src/mempool.zig`, `src/rpc/` exist yet

---

## Reference Implementations

### 1. TEVM — Primary Shape Reference

**`handleAutomining.js`** — `../tevm-monorepo/packages/actions/src/Call/handleAutomining.js`
```javascript
export const handleAutomining = async (client, txHash, _reserved = false, mineAllTx = true) => {
    const mineRes = await mineHandler(client)({
        ...(mineAllTx || txHash === undefined ? {} : { tx: txHash }),
        throwOnFail: false,
        blockCount: 1,
    })
    if (mineRes.errors?.length) return mineRes
    return undefined
}
```

Key behaviors:
- Always mines exactly **1 block**
- When called from `eth_sendRawTransaction`/`eth_sendTransaction`, passes `mineAllTx: true` (mine the entire mempool, not just the specific tx)
- Returns errors as values, never throws
- Short-circuits on error (does not proceed)

**`ethSendRawTransactionProcedure.js`** — `../tevm-monorepo/packages/actions/src/eth/ethSendRawTransactionProcedure.js`
```javascript
// After adding tx to pool and getting txHash:
if (client.miningConfig.type === 'auto') {
    await handleAutomining(client, bytesToHex(tx.hash()), false, true)
}
return txHash
```

**`ethSendTransactionProcedure.js`** — `../tevm-monorepo/packages/actions/src/eth/ethSendTransactionProcedure.js`
```javascript
// After calling ethSendTransactionHandler and getting txHash:
if (client.miningConfig.type === 'auto') {
    await handleAutomining(client, txHash, false, true)
}
return txHash
```

**Integration test** — `../tevm-monorepo/packages/actions/src/eth/ethJsonRpcAutomining.spec.ts`
- **Automine ON**: `eth_sendRawTransaction` → tx added to pool → block mined → `eth_blockNumber` incremented → receipt available
- **Automine OFF** (`manual`): `eth_sendRawTransaction` → tx added to pool → block NOT mined → receipt `null`, block number unchanged
- **`eth_estimateGas` never triggers automining**, even with automine ON; no tx added to pool

**`mineHandler.js`** — `../tevm-monorepo/packages/actions/src/Mine/mineHandler.js`
Key mine logic (relevant subset):
1. Deep copy the VM
2. Get pending transactions from pool via `txsByPriceAndNonce()`
3. Build block: `vm.buildBlock({ parentBlock, headerData: { timestamp, number: parent+1n, ... } })`
4. Add each tx via `blockBuilder.addTransaction(nextTx, { skipBalance: true, skipNonce: true })`
5. `vm.stateManager.checkpoint()` → `vm.stateManager.commit()`
6. `blockBuilder.build()` → `vm.blockchain.putBlock(block)`
7. Sync state back to original VM
8. Remove mined txs from pool
9. Emit block/receipt events

---

### 2. Hardhat EDR — Secondary Reference

**`data.rs`** — `edr/crates/edr_provider/src/data.rs`

Transaction submission flow (`send_transaction`):
```rust
// Step 1: If automining, validate first (strict nonce/fee checks)
let snapshot_id = if self.is_auto_mining {
    self.validate_auto_mine_transaction(&transaction)?;
    Some(self.make_snapshot())
} else {
    None
};

// Step 2: Add to mempool
let txhash = self.add_pending_transaction(transaction)?;

// Step 3: If automining, mine blocks until tx is included
if self.is_auto_mining {
    loop {
        let mined_block_and_results = self.mine_block(MineBlockRequest::default())?;
        // ... if tx included, break
        // continue if more pending txs remain
    }
}
```

Key EDR automine validations (enforced before adding to mempool):
- Nonce must equal account's next nonce (no gaps, no replays)
- Priority fee >= `min_gas_price`
- For EIP-1559: `max_fee_per_gas` >= next block's base fee
- Snapshot created before mining; rolls back on failure

EDR mines until the submitted tx is included (handles gas-limit edge cases by mining multiple blocks).

---

### 3. Foundry Anvil — Reference

**`api.rs`** — `foundry/crates/anvil/src/eth/api.rs`

```rust
pub async fn eth_send_raw_transaction(&self, tx: Bytes) -> Result<TxHash> {
    let tx = self.pool.add_transaction(tx)?;
    if self.miner.is_auto_mine() {
        self.do_mine().await;
    }
    Ok(tx.hash())
}
```

Foundry's `mine_one()`:
```rust
pub async fn mine_one(&self) {
    let transactions = self.pool.ready_transactions().collect::<Vec<_>>();
    let outcome = self.backend.mine_block(transactions).await;
    self.pool.on_mined_block(outcome);
}
```

Foundry does exactly one `mine_one()` call per automine trigger (simpler than EDR's loop).

---

## Integration Contract (What ZEVM-006 Must Implement)

### Trigger Points

Both RPC handlers must include this check immediately after successfully adding the tx to the mempool and obtaining a `tx_hash`:

```zig
// Pseudocode — see implementation section for actual Zig
if (node.mining_config == .auto) {
    try mineOneBlock(allocator, node);
}
```

### Mining Logic Required

The automine trigger needs:
1. **Retrieve pending transactions** from mempool (ordered by gas price / nonce)
2. **Build a block**: use existing `block_builder.buildBlock()` with a computed `BlockContext`
   - `block_number = head_block_number + 1`
   - `block_timestamp = max(now, parent_timestamp + 1)` (monotonic)
   - `block_gas_limit` from node config (or copy parent's limit)
   - `chain_id` from node config
3. **Commit state** via `StateManager`
4. **Store block** via voltaire's `Blockchain.putBlock()` + `Blockchain.setCanonicalHead()`
5. **Remove mined transactions** from mempool
6. **Return error or success** — return the error as a value; the tx hash is still returned to the caller even if mining fails (matches TEVM behavior)

### When NOT to Mine (Automine Gate)
- `mining_config == .manual` → skip mining entirely
- `mining_config == .interval` → skip mining (interval loop handles it)
- Called from `eth_estimateGas` or `eth_call` → never automine (those are read-only paths)

---

## Mempool Dependency

ZEVM-006 depends on a pending transaction pool. This does not exist yet in ZEVM. Options:

1. **In-ZEVM `src/mempool.zig`** — simple `ArrayList` of `(Address, LegacyTransaction)` tuples sorted by `(gas_price DESC, nonce ASC)`. The minimal viable mempool for automine.
2. **In voltaire** — if voltaire grows a mempool type, use that. For now, a simple ZEVM-local mempool is acceptable because ZEVM is the integration layer.

Minimum mempool interface needed for ZEVM-006:
```zig
// Add a transaction to the pending pool
pub fn addTx(self: *Mempool, allocator: std.mem.Allocator, caller: primitives.Address, tx: primitives.Transaction.LegacyTransaction) !primitives.Hash.Hash

// Drain all pending transactions in gas-price / nonce order
pub fn drainPending(self: *Mempool, allocator: std.mem.Allocator) ![]tx_processor.ExecutionTx

// Remove a slice of transactions (post-mining cleanup)
pub fn removeMinedTxs(self: *Mempool, hashes: []const primitives.Hash.Hash) void
```

---

## eth_sendRawTransaction Handler Design

**Params**: `[rawTx: hex_string]`
**Returns**: transaction hash (`0x...`)

Flow:
1. Hex-decode the raw bytes
2. Decode RLP envelope — determine tx type (legacy `0x00`, EIP-2930 `0x01`, EIP-1559 `0x02`, blob `0x03`)
3. For ZEVM-006 scope: legacy only (EIP-1559 and others are ZEVM-005+ territory)
4. Validate signature (or skip for impersonated txs — ZEVM impersonation is a later ticket)
5. Add to mempool → get `tx_hash`
6. **If `node.mining_config == .auto`**: call `mineBlock(node)`
7. Return `tx_hash`

**Parsing**: voltaire `primitives` module has `Transaction.LegacyTransaction` and `Transaction.encodeLegacyForSigning`. Need RLP decode. Check if voltaire `primitives` has an RLP decoder; if not, add one there (we own voltaire).

---

## eth_sendTransaction Handler Design

**Params**: transaction object `{from, to?, gas?, gasPrice?, value?, data?, nonce?}`
**Returns**: transaction hash (`0x...`)

Flow:
1. Parse JSON params into `primitives.Transaction.LegacyTransaction` (with defaults: `gas_price = baseFee`, `nonce = getTransactionCount(from)`, `value = 0`, `data = &.{}`)
2. Sign: for dev node, all accounts are pre-funded and "impersonated" — no real signing needed; create an unsigned tx and skip signature checks
3. Add to mempool → get `tx_hash`
4. **If `node.mining_config == .auto`**: call `mineBlock(node)`
5. Return `tx_hash`

---

## Block Building During Automine

The existing `block_builder.buildBlock()` requires a `guillotine_mini.BlockContext`. The automine trigger must construct this:

```zig
const parent_block = try node.blockchain.getCanonicalHeadBlock();
const now_secs: u64 = @intCast(std.time.timestamp());
const block_ctx = guillotine_mini.BlockContext{
    .block_number = parent_block.header.number + 1,
    .block_timestamp = @max(now_secs, parent_block.header.timestamp + 1),
    .block_gas_limit = parent_block.header.gas_limit,
    .chain_id = node.chain_id,
    .block_coinbase = node.coinbase,
    .block_difficulty = 0, // post-merge
    .block_base_fee = parent_block.header.base_fee_per_gas orelse 0,
};
```

After `buildBlock()` returns `BlockResult`, the block header must be finalized and stored:
- Compute state root via `database.syncCachedAccountsToTrie()` → trie root
- Construct `primitives.BlockHeader` from block_ctx + state_root + receipt_root
- Call `node.blockchain.putBlock(block)` and `node.blockchain.setCanonicalHead(block_hash)`

---

## Node Struct (ZevmNode) Fields Required for ZEVM-006

ZEVM-001 defines `ZevmNode` with only `mining_config`. ZEVM-006 additionally needs:

```zig
pub const ZevmNode = struct {
    mining_config: @import("mining.zig").MiningConfig,   // from ZEVM-001
    chain_id: u64,
    coinbase: primitives.Address,
    db: @import("database/root.zig").database.Database,
    blockchain: blockchain.Blockchain,
    mempool: @import("mempool.zig").Mempool,
    // ... (future: receipts store, filters, snapshots)
};
```

---

## Key Upstream Files

### voltaire — We Own This

| File | Relevance |
|------|-----------|
| `../voltaire/packages/voltaire-zig/src/state-manager/StateManager.zig` | `checkpoint()`, `commit()`, `revert()`, `snapshot()` |
| `../voltaire/packages/voltaire-zig/src/blockchain/Blockchain.zig` | `putBlock()`, `setCanonicalHead()`, `getCanonicalHeadBlock()` |
| `../voltaire/packages/voltaire-zig/src/blockchain/BlockStore.zig` | Canonical chain tracking, orphan handling |
| `../voltaire/packages/voltaire-zig/src/jsonrpc/eth/methods.zig` | Pattern for adding new RPC method type files |

### voltaire gaps to fix if needed
- `eth_sendRawTransaction` and `eth_sendTransaction` Params/Result types already exist in `jsonrpc/eth/methods.zig` per the voltaire summary (40+ methods)
- If RLP decode of raw transactions is missing from `primitives`, add it to voltaire

### guillotine-mini — We Own This
- `src/root.zig` exports `HostInterface`, `BlockContext`, `Evm`, `Log`
- No `client/rpc` source tree in current checkout (confirmed in ZEVM-001 context)

---

## Error Handling Contract

Following TEVM's philosophy:
- The RPC handler always returns the `tx_hash` on successful submission
- If automine mining fails, the error is **logged** but the tx_hash is still returned to the caller
- Mining failures do NOT cause the `eth_sendRawTransaction` / `eth_sendTransaction` call to fail
- This matches TEVM's `handleAutomining` returning errors as values while the procedure handler ignores them

Exception: If the transaction itself is invalid (bad nonce, insufficient balance at validation), return a JSON-RPC error before attempting to add to mempool.

---

## Test Cases to Port

### From TEVM (`ethJsonRpcAutomining.spec.ts`)

1. **Automine ON — tx gets mined immediately**
   - Setup: `mining_config = .auto`
   - Action: `eth_sendRawTransaction(signed_legacy_tx)`
   - Assert: `eth_blockNumber` increased by 1
   - Assert: `eth_getTransactionReceipt(tx_hash)` is non-null
   - Assert: Receipt `block_number` == new head

2. **Automine OFF — tx sits in mempool**
   - Setup: `mining_config = .manual`
   - Action: `eth_sendRawTransaction(signed_legacy_tx)`
   - Assert: `eth_blockNumber` unchanged
   - Assert: `eth_getTransactionReceipt(tx_hash)` returns null
   - Assert: Tx visible via `eth_getTransactionByHash` (pending)

3. **eth_estimateGas does NOT trigger automine**
   - Setup: `mining_config = .auto`
   - Action: `eth_estimateGas({from, to, value})`
   - Assert: `eth_blockNumber` unchanged
   - Assert: No tx in mempool after call

4. **Multiple txs from same sender — nonces sequential**
   - Submit tx with nonce 0, then nonce 1
   - With automine ON, each submission mines a block
   - Both receipts exist in separate blocks

5. **Automine: tx revert still mines block**
   - Send tx that will revert (e.g., call non-existent contract)
   - Assert: Block is mined (block_number incremented)
   - Assert: Receipt exists with `status = 0` (failed)

### From Foundry (`anvil_api.rs` / `anvil.rs`)

6. **Toggle automine mid-session**
   - Send tx1 with automine ON → block 2 exists
   - `evm_setAutomine(false)` → automine OFF
   - Send tx2 → no new block
   - `evm_mine()` → block 3 mined with tx2

---

## Implementation Order

1. **`src/mempool.zig`** — minimal pending tx pool
2. **`src/mining.zig`** + **`src/node.zig`** — MiningConfig + ZevmNode (per ZEVM-001 plan)
3. **`src/rpc/eth/send_transaction.zig`** — `eth_sendTransaction` handler
4. **`src/rpc/eth/send_raw_transaction.zig`** — `eth_sendRawTransaction` handler
5. **Wire automine trigger** into both handlers (the actual ZEVM-006 delta)
6. **Tests** in `src/rpc/eth/send_transaction_test.zig` and `src/rpc/eth/send_raw_transaction_test.zig`

ZEVM-006's core change is ~5-10 lines in each handler:
```zig
// After mempool.addTx():
if (node.mining_config == .auto) {
    mineOneBlock(allocator, node) catch |err| {
        // Log error but continue — tx_hash is still valid
        std.log.warn("automine failed: {}", .{err});
    };
}
```

---

## Zig Style Constraints (from CLAUDE.md)

- **No local type aliases**: write `primitives.Transaction.LegacyTransaction` inline, not `const LegacyTx = ...`
- **No stored allocators**: pass `allocator` explicitly to `mineOneBlock`, `mempool.addTx`, etc.
- **No useless wrappers**: if automine check is 2 lines, inline it; don't create a `handleAutominingZig()` wrapper
- **Fully qualified paths** everywhere in implementation files

---

## Open Questions

1. **RLP decode**: Does voltaire `primitives` expose an RLP transaction decoder? Check `../voltaire/packages/voltaire-zig/src/` — if not, add `Transaction.decodeLegacyRlp()` to voltaire.
2. **EIP-1559 support**: ZEVM-006 can start with legacy-only. EIP-1559 parsing and fee logic is a follow-on.
3. **Signature validation**: Dev node behavior is to skip (impersonation). Confirm dev-mode never validates sigs for locally-submitted txs.
4. **Blockchain integration**: `voltaire/blockchain/BlockStore.zig` `putBlock` stub returns `NOT_IMPLEMENTED` in the C API — confirm the Zig-native `putBlock` is fully functional.
5. **Thread safety**: If mining is called concurrently (interval + automine), need a mutex. For now, single-threaded model is fine.

---

## Files to Create / Modify

### New in ZEVM
| File | Purpose |
|------|---------|
| `src/mempool.zig` | Pending tx pool (ordered by gas price / nonce) |
| `src/mempool_test.zig` | Tests for mempool add/drain/remove |
| `src/rpc/eth/send_transaction.zig` | `eth_sendTransaction` handler |
| `src/rpc/eth/send_raw_transaction.zig` | `eth_sendRawTransaction` handler |
| `src/rpc/eth/send_transaction_test.zig` | Tests including automine behavior |
| `src/rpc/eth/send_raw_transaction_test.zig` | Tests including automine behavior |

### Modified in ZEVM
| File | Change |
|------|--------|
| `src/node.zig` | Add `mempool` + `blockchain` fields (builds on ZEVM-001) |
| `src/root.zig` | Export `mempool`, RPC handlers, add test imports |

### Possibly Modified in Voltaire
| File | Change (if needed) |
|------|-------------------|
| `../voltaire/.../primitives/Transaction.zig` | Add `decodeLegacyRlp()` if not present |

---

## Summary of ZEVM-006 Delta

ZEVM-006's net-new work, assuming ZEVM-001/002/003 are done:
1. Add automine check (2 lines) to `eth_sendTransaction` handler
2. Add automine check (2 lines) to `eth_sendRawTransaction` handler
3. Implement or wire `mineOneBlock()` function that calls `block_builder.buildBlock()` + commits + stores
4. Write automine integration tests (cases 1–5 above)

The bulk of the complexity is in dependencies (mempool, block storage, tx parsing) that ZEVM-003 and ZEVM-002 should cover. ZEVM-006 is the glue between "tx submitted" and "block mined."
