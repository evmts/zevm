# Plan: add-mempool-to-voltaire

## Overview

Add a transaction pool (mempool) module to voltaire at `../voltaire/packages/voltaire-zig/src/txpool/`. This implements the core data structure for holding pending/ready transactions, ordered by nonce and fee priority, with support for all Ethereum transaction types (Legacy, EIP-1559, EIP-2930, EIP-4844, EIP-7702).

**Design model**: Adapted from Foundry's `requires`/`provides` marker pattern where each transaction provides marker `(nonce, sender)` and requires marker `(nonce-1, sender)` (unless nonce equals on-chain nonce). This cleanly separates ready vs pending transactions and handles promotion when predecessors are mined.

**Scope**: This is a voltaire-only change. ZEVM integration is a follow-up ticket.

## Prerequisites / Missing Pieces in Voltaire

Before building the txpool, we need a few small additions in voltaire:

1. **EIP-2930 transaction struct** - `TransactionType.eip2930` exists as an enum variant but there is no `Eip2930Transaction` struct in `Transaction.zig`
2. **Intrinsic gas calculation** - `GasConstants` has `TxGas`, `TxDataZeroGas`, etc. but no `calcIntrinsicGas()` function and no EIP-2930 access list gas constants (`ACCESS_LIST_ADDRESS_COST = 2400`, `ACCESS_LIST_STORAGE_KEY_COST = 1900`) or EIP-7702 per-auth cost (`PER_AUTH_BASE_COST = 12500`)
3. **Sender recovery from transaction** - `secp256k1.recoverPubkey()` and `secp256k1.unauditedRecoverAddress()` exist but there's no `recoverSender(tx)` that hashes the unsigned tx envelope and recovers the address

These will be added as part of the TDD steps below (in voltaire, not zevm).

## File Plan

### New files (voltaire)

| File | Purpose |
|---|---|
| `src/txpool/TxPool.zig` | Main txpool struct with `add`, `remove`, `get_pending`, `get_ready`, `clear`, `on_mined_block` |
| `src/txpool/root.zig` | Module root, re-exports |

### Modified files (voltaire)

| File | Change |
|---|---|
| `src/primitives/Transaction/Transaction.zig` | Add `Eip2930Transaction` struct, add unified `TransactionEnvelope` tagged union, add `getSender()`, `getNonce()`, `getGasPrice()`, `getMaxFeePerGas()` helpers on envelope |
| `src/primitives/GasConstants/gas_constants.zig` | Add `AccessListAddressCost`, `AccessListStorageKeyCost`, `PerAuthBaseCost`, `InitCodeWordCost` constants |
| `src/primitives/root.zig` | Re-export `TxPool` if needed (or keep separate module) |
| `build.zig` | Add `txpool` module with imports of `primitives`, `crypto`; add txpool test step |

## Internal Data Model

```
TxPool
  |
  +-- by_hash: HashMap(Hash, *PoolEntry)          -- O(1) lookup/remove by hash
  |
  +-- by_sender: HashMap(Address, SenderQueue)     -- per-sender nonce-ordered queues
  |     |
  |     +-- SenderQueue
  |           +-- ready: BTreeMap-like (nonce -> *PoolEntry)   -- nonce >= on-chain, contiguous
  |           +-- pending: BTreeMap-like (nonce -> *PoolEntry) -- nonce gaps, future txs
  |           +-- next_nonce: u64                              -- next expected nonce (from state)
  |
  +-- ready_queue: PriorityQueue(PoolEntryRef)     -- global fee-priority ordering for mining
  |
  +-- insertion_counter: u64                       -- monotonic counter for tie-breaking

PoolEntry
  +-- envelope: TransactionEnvelope               -- the transaction
  +-- hash: Hash                                  -- tx hash
  +-- sender: Address                             -- recovered sender
  +-- nonce: u64                                  -- cached nonce
  +-- effective_gas_price: u256                   -- for priority ordering
  +-- max_fee_per_gas: u256                       -- for replacement checks
  +-- max_fee_per_blob_gas: ?u256                 -- for blob replacement checks
  +-- insertion_id: u64                           -- tie-breaker
```

## Error Types

```zig
pub const TxPoolError = error{
    AlreadyKnown,              // duplicate hash
    ReplacementUnderpriced,    // same sender+nonce but fee too low
    NonceTooLow,               // nonce < on-chain nonce
    InsufficientFunds,         // balance < value + gas * gasPrice
    IntrinsicGasTooLow,        // gas_limit < intrinsic gas
    GasLimitExceeded,          // gas_limit > block gas limit
    InvalidSender,             // signature recovery failed
    SenderIsContract,          // EIP-3607
    NonceMaxValue,             // EIP-2681 nonce >= 2^64-1
    BlobTxContractCreation,    // EIP-4844: no create
    EmptyAuthorizationList,    // EIP-7702: empty auth list
    OutOfMemory,
};
```

## TDD Step Order

### Phase 1: Transaction Envelope Prerequisites

#### Step 1: Test — Eip2930Transaction struct
**File**: `src/primitives/Transaction/Transaction.zig`

Add tests that construct an `Eip2930Transaction` and verify field access:
- `"Eip2930Transaction struct field access"`
- `"Eip2930Transaction with access list"`

Then add the struct (mirrors `Eip1559Transaction` but with `gas_price` instead of `max_fee_per_gas`/`max_priority_fee_per_gas`).

#### Step 2: Test — TransactionEnvelope tagged union
**File**: `src/primitives/Transaction/Transaction.zig`

Add tests:
- `"TransactionEnvelope wraps legacy transaction"`
- `"TransactionEnvelope wraps eip1559 transaction"`
- `"TransactionEnvelope wraps eip4844 transaction"`
- `"TransactionEnvelope wraps eip7702 transaction"`
- `"TransactionEnvelope wraps eip2930 transaction"`
- `"TransactionEnvelope.nonce returns correct nonce for all types"`
- `"TransactionEnvelope.gasLimit returns correct gas limit for all types"`

Then implement `TransactionEnvelope` as:
```zig
pub const TransactionEnvelope = union(TransactionType) {
    legacy: LegacyTransaction,
    eip2930: Eip2930Transaction,
    eip1559: Eip1559Transaction,
    eip4844: Eip4844Transaction,
    eip7702: Eip7702Transaction,
};
```

Plus inline accessor helpers: `nonce()`, `gasLimit()`, `value()`, `sender()` (deferred), `to()`.

#### Step 3: Test — Gas constants for access list / auth / initcode
**File**: `src/primitives/GasConstants/gas_constants.zig`

Add tests:
- `"AccessListAddressCost is 2400"`
- `"AccessListStorageKeyCost is 1900"`
- `"PerAuthBaseCost is 12500"`
- `"InitCodeWordCost is 2"`

Then add the constants.

#### Step 4: Test — Intrinsic gas calculation
**File**: `src/primitives/GasConstants/gas_constants.zig` (or a new `src/primitives/Gas/intrinsic.zig`)

Add tests:
- `"calcIntrinsicGas simple ETH transfer is 21000"`
- `"calcIntrinsicGas contract creation adds 32000"`
- `"calcIntrinsicGas calldata zero bytes cost 4 each"`
- `"calcIntrinsicGas calldata non-zero bytes cost 16 each"`
- `"calcIntrinsicGas with access list adds address and key costs"`
- `"calcIntrinsicGas with EIP-7702 auth list adds per-auth cost"`

Then implement `calcIntrinsicGas(envelope: TransactionEnvelope) u64`.

#### Step 5: Test — Effective gas price helpers on TransactionEnvelope
**File**: `src/primitives/Transaction/Transaction.zig`

Add tests:
- `"TransactionEnvelope.effectiveGasPrice legacy returns gas_price"`
- `"TransactionEnvelope.effectiveGasPrice eip1559 returns min(maxFee, baseFee+priorityFee)"`
- `"TransactionEnvelope.effectiveGasPrice eip2930 returns gas_price"`
- `"TransactionEnvelope.maxFeePerGas legacy returns gas_price"`
- `"TransactionEnvelope.maxFeePerGas eip1559 returns max_fee_per_gas"`
- `"TransactionEnvelope.maxFeePerBlobGas returns value for eip4844 else null"`

Then implement the methods on `TransactionEnvelope`.

### Phase 2: TxPool Core — Empty Pool

#### Step 6: Test — TxPool init/deinit
**File**: `src/txpool/TxPool.zig`

Add tests:
- `"TxPool init creates empty pool"`
- `"TxPool init and deinit does not leak"`
- `"TxPool.count returns 0 for empty pool"`

Then implement:
```zig
pub fn init(allocator: std.mem.Allocator) TxPool { ... }
pub fn deinit(self: *TxPool, allocator: std.mem.Allocator) void { ... }
pub fn count(self: *const TxPool) usize { ... }
```

#### Step 7: Test — TxPool.clear
**File**: `src/txpool/TxPool.zig`

- `"TxPool.clear empties all queues"`

Implement `pub fn clear(self: *TxPool, allocator: std.mem.Allocator) void`.

### Phase 3: TxPool Core — Add Transaction

#### Step 8: Test — add_transaction happy path (single legacy tx)
**File**: `src/txpool/TxPool.zig`

- `"add_transaction inserts legacy tx and returns hash"`
- `"add_transaction makes tx retrievable by hash"`
- `"add_transaction with matching nonce goes to ready queue"`
- `"count returns 1 after single add"`

Implement `pub fn add_transaction(self: *TxPool, allocator: std.mem.Allocator, envelope: TransactionEnvelope, sender: Address, next_nonce: u64, base_fee: u64) TxPoolError!Hash`.

Note: In the MVP, the caller passes in `sender` (already recovered) and `next_nonce` (from state). This keeps the txpool pure data structure without needing state access. Validation is the caller's job for now (can be wrapped in a higher-level `submit_transaction` later).

#### Step 9: Test — add_transaction all tx types
**File**: `src/txpool/TxPool.zig`

- `"add_transaction inserts eip1559 tx"`
- `"add_transaction inserts eip2930 tx"`
- `"add_transaction inserts eip4844 tx"`
- `"add_transaction inserts eip7702 tx"`

#### Step 10: Test — add_transaction nonce ordering (ready vs pending)
**File**: `src/txpool/TxPool.zig`

- `"add_transaction with future nonce goes to pending not ready"`
- `"add_transaction with exact next nonce goes to ready"`
- `"add_transaction with nonce gap places in pending"`

#### Step 11: Test — add_transaction duplicate rejection
**File**: `src/txpool/TxPool.zig`

- `"add_transaction rejects duplicate hash with AlreadyKnown"`
- `"add_transaction rejects nonce below on-chain with NonceTooLow"`

#### Step 12: Test — add_transaction replacement
**File**: `src/txpool/TxPool.zig`

- `"add_transaction replaces same sender+nonce with higher fee"`
- `"add_transaction rejects same sender+nonce with lower fee as ReplacementUnderpriced"`
- `"add_transaction rejects same sender+nonce with equal fee as ReplacementUnderpriced"`
- `"add_transaction replacement for blob tx requires both fee bumps"`

### Phase 4: TxPool Core — Retrieval

#### Step 13: Test — get_pending
**File**: `src/txpool/TxPool.zig`

- `"get_pending returns all transactions (ready + pending)"`
- `"get_pending returns empty slice for empty pool"`
- `"get_pending_by_sender returns only that sender's txs"`

Implement:
```zig
pub fn get_pending(self: *const TxPool, allocator: std.mem.Allocator) ![]PoolEntry { ... }
pub fn get_pending_by_sender(self: *const TxPool, allocator: std.mem.Allocator, sender: Address) ![]PoolEntry { ... }
```

#### Step 14: Test — get_ready
**File**: `src/txpool/TxPool.zig`

- `"get_ready returns only ready transactions"`
- `"get_ready returns transactions ordered by effective gas price descending"`
- `"get_ready respects nonce ordering within same sender"`
- `"get_ready returns empty slice when no ready txs"`
- `"get_ready with tie uses insertion order (FIFO)"`

Implement:
```zig
pub fn get_ready(self: *const TxPool, allocator: std.mem.Allocator, base_fee: u64) ![]PoolEntry { ... }
```

#### Step 15: Test — get_transaction (by hash)
**File**: `src/txpool/TxPool.zig`

- `"get_transaction returns tx for known hash"`
- `"get_transaction returns null for unknown hash"`

Implement:
```zig
pub fn get_transaction(self: *const TxPool, hash: [32]u8) ?*const PoolEntry { ... }
```

### Phase 5: TxPool Core — Remove & Promotion

#### Step 16: Test — remove_transaction
**File**: `src/txpool/TxPool.zig`

- `"remove_transaction removes known tx and returns true"`
- `"remove_transaction returns false for unknown hash"`
- `"remove_transaction decrements count"`
- `"remove_transaction removes from sender queue"`

Implement:
```zig
pub fn remove_transaction(self: *TxPool, allocator: std.mem.Allocator, hash: [32]u8) bool { ... }
```

#### Step 17: Test — on_mined_block promotion
**File**: `src/txpool/TxPool.zig`

This is the critical nonce-gap-filling test:

- `"on_mined_block removes included txs"`
- `"on_mined_block promotes pending tx when predecessor mined"`
- `"on_mined_block promotes chain of pending txs"`
- `"on_mined_block updates next_nonce for sender"`
- `"on_mined_block handles multiple senders"`

Implement:
```zig
pub const MinedBlockResult = struct {
    removed: []const [32]u8,
    promoted: []const [32]u8,
};

pub fn on_mined_block(
    self: *TxPool,
    allocator: std.mem.Allocator,
    mined_hashes: []const [32]u8,
    sender_nonces: []const struct { sender: Address, new_nonce: u64 },
) !MinedBlockResult { ... }
```

### Phase 6: Build Integration

#### Step 18: Module registration in build.zig
**File**: `build.zig`

- Add `txpool` module with root `src/txpool/root.zig`
- Add `txpool_mod.addImport("primitives", primitives_mod)`
- Add `txpool_mod.addImport("crypto", crypto_mod)`
- Create txpool test step and add to `test_step`

#### Step 19: root.zig
**File**: `src/txpool/root.zig`

```zig
pub const TxPool = @import("TxPool.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
```

### Phase 7: Integration Tests

#### Step 20: Test — Full lifecycle integration
**File**: `src/txpool/TxPool.zig` (bottom of file)

- `"integration: add 3 txs from same sender, mine first, verify promotion"`
  1. Add tx with nonce 0, 1, 2 from same sender (next_nonce=0)
  2. Verify get_ready returns [nonce 0]
  3. Call on_mined_block with nonce 0
  4. Verify get_ready now returns [nonce 1]
  5. Call on_mined_block with nonce 1
  6. Verify get_ready now returns [nonce 2]

- `"integration: multi-sender fee priority ordering"`
  1. Add tx from sender A (gas_price=10), sender B (gas_price=20), sender C (gas_price=15)
  2. Verify get_ready returns [B, C, A]

- `"integration: replacement then mine"`
  1. Add tx nonce=0 with gas_price=10
  2. Replace with gas_price=20 (same sender+nonce)
  3. Verify get_ready returns the replacement
  4. Mine it, verify pool empty

- `"integration: clear after multiple adds"`
  1. Add several transactions
  2. Call clear
  3. Verify count is 0, get_pending returns empty

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| **TransactionEnvelope is a big change to Transaction.zig** | Keep it additive — existing types unchanged, envelope is new union wrapping them |
| **No sender recovery in txpool itself** | MVP has caller pass `sender` address. Follow-up adds `submit_raw_transaction()` that decodes + recovers + calls `add_transaction()` |
| **No state access in txpool** | By design — pool is a pure data structure. Caller passes `next_nonce` and `balance`. This matches Foundry's design where the pool doesn't own state |
| **Missing EIP-2930 struct** | Added in Phase 1 Step 1 — it's the simplest struct to add |
| **Performance with many senders** | Use HashMap for by_sender index (O(1) lookup), std.PriorityQueue for ready ordering. Good enough for dev node scale (thousands of txs, not millions) |
| **Thread safety** | Not needed for MVP (single-threaded dev node). Can add RwLock wrapper later |
| **Blob tx replacement requires both fee bumps** | Explicitly tested in Step 12 |

## Verification Against Acceptance Criteria

| Criterion | How Verified |
|---|---|
| Support Legacy, EIP-1559, EIP-2930, EIP-4844, EIP-7702 | Steps 1-2 (TransactionEnvelope), Steps 8-9 (add all types) |
| `add_transaction()` | Steps 8-12 |
| `remove_transaction()` | Step 16 |
| `get_pending()` | Step 13 |
| `get_ready()` / `ready_transactions()` | Step 14 |
| `clear()` | Step 7 |
| Nonce-aware per-account ordering | Steps 10, 17, 20 |
| Gas-priority ordering for mining | Steps 14, 20 |
| Replacement policy | Step 12 |
| Post-mine promotion | Step 17, 20 |
| All tests pass with `zig build test` in voltaire | Step 18 (build integration) |

## Implementation Order Summary

1. **Phase 1** (Steps 1-5): Transaction prerequisites in `primitives/`
2. **Phase 2** (Steps 6-7): Empty pool scaffolding
3. **Phase 3** (Steps 8-12): Core add logic with validation
4. **Phase 4** (Steps 13-15): Retrieval queries
5. **Phase 5** (Steps 16-17): Remove and promotion
6. **Phase 6** (Steps 18-19): Build system wiring
7. **Phase 7** (Step 20): Integration tests

Total: ~50+ test cases across 20 steps. Each step is one test file edit + one implementation pass.
