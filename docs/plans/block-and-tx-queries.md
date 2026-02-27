# Plan: Block and Transaction Query RPC Methods

## Overview

This plan implements 10 read-only JSON-RPC methods for block, transaction, receipt, and log
queries. The approach is TDD: write failing tests first, then implement each layer.

All storage primitives already exist in **voltaire** (`Blockchain`, `Receipt`, `EventLog`,
`Block`, `BlockBody`). ZEVM adds only three new layers:

1. **Receipt/Log index** — a thin in-memory store keyed by tx hash and block hash
2. **RPC handler functions** — one function per method that queries the index + blockchain
3. **Tests** — unit tests per handler and integration tests validating execution-apis vectors

No stored allocators. No local type aliases. Pass allocator explicitly everywhere.

---

## Architecture Summary

```
RPC dispatch (existing)
    ↓
src/rpc/block_queries.zig     ← NEW: handler functions for all 10 methods
    ↓
src/receipt_index.zig          ← NEW: ReceiptIndex (tx_hash→receipt, block_hash→[]receipt)
src/log_index.zig              ← NEW: LogIndex (block-range scan + address/topic filter)
    ↓
blockchain.Blockchain          ← EXISTING voltaire: block by hash/number
primitives.Receipt.Receipt     ← EXISTING voltaire: receipt model
primitives.EventLog.EventLog   ← EXISTING voltaire: log model
```

---

## TDD Step Order

Tests are written before implementation. Each step produces one or more failing tests that
are made green by the following implementation step.

---

### STEP 1 — Test: ReceiptIndex basic put/get

**File:** `src/receipt_index_test.zig`

Tests to write:
```
test "receipt_index: store and retrieve by tx hash"
test "receipt_index: missing tx hash returns null"
test "receipt_index: store and retrieve block receipts by block hash"
test "receipt_index: block hash with no receipts returns empty slice"
test "receipt_index: missing block hash returns null (not found vs empty)"
test "receipt_index: multiple receipts stored per block in tx-index order"
test "receipt_index: deinit frees all memory"
```

---

### STEP 2 — Implement: ReceiptIndex

**File:** `src/receipt_index.zig`

```zig
pub const ReceiptIndex = struct {
    // tx_hash → primitives.Receipt.Receipt (owned)
    by_tx: std.AutoHashMap([32]u8, primitives.Receipt.Receipt),
    // block_hash → owned slice of receipts in tx-index order
    by_block: std.AutoHashMap([32]u8, []primitives.Receipt.Receipt),
};

pub fn init(allocator: std.mem.Allocator) ReceiptIndex
pub fn deinit(self: *ReceiptIndex, allocator: std.mem.Allocator) void

/// Store receipts for a sealed block. Inserts into both indexes.
/// Receipts must have block_hash, block_number, transaction_index populated.
pub fn putBlockReceipts(
    self: *ReceiptIndex,
    allocator: std.mem.Allocator,
    block_hash: [32]u8,
    receipts: []const primitives.Receipt.Receipt,
) !void

/// Returns receipt for a tx hash, or null if not found.
pub fn getByTxHash(
    self: *ReceiptIndex,
    tx_hash: [32]u8,
) ?primitives.Receipt.Receipt

/// Returns ordered receipts slice for a block hash.
/// Returns null if block_hash was never stored (not found).
/// Returns empty slice if block was stored with zero transactions.
pub fn getByBlockHash(
    self: *ReceiptIndex,
    block_hash: [32]u8,
) ?[]const primitives.Receipt.Receipt
```

---

### STEP 3 — Test: LogIndex basic operations

**File:** `src/log_index_test.zig`

Tests to write:
```
test "log_index: append and retrieve all logs for a block"
test "log_index: scan range returns logs in canonical order (blockNumber, txIndex, logIndex)"
test "log_index: filter by single address"
test "log_index: filter by address array (OR semantics)"
test "log_index: filter by exact topic at position 0"
test "log_index: null topic is wildcard — matches any"
test "log_index: topic OR array at same position"
test "log_index: blockHash-specific query returns only that block's logs"
test "log_index: empty range returns empty slice"
test "log_index: deinit frees all memory"
```

---

### STEP 4 — Implement: LogIndex

**File:** `src/log_index.zig`

```zig
/// Filter parameters matching eth_getLogs spec.
pub const LogFilter = struct {
    from_block: ?u64 = null,
    to_block: ?u64 = null,
    block_hash: ?[32]u8 = null,
    // null address list = match all
    addresses: ?[]const [20]u8 = null,
    // topics[i] = null means wildcard; topics[i] = &[hash, ...] means OR
    topics: ?[]const ?[]const [32]u8 = null,
};

pub const LogIndex = struct {
    // Ordered list of all indexed logs with full metadata
    logs: std.ArrayList(primitives.EventLog.EventLog),
    // block_number → (start_idx, end_idx) into logs slice for fast range scan
    block_range: std.AutoHashMap(u64, struct { start: usize, end: usize }),
};

pub fn init(allocator: std.mem.Allocator) LogIndex
pub fn deinit(self: *LogIndex, allocator: std.mem.Allocator) void

/// Append all logs from a mined block. Must be called in ascending block order.
/// Sets block_number, transaction_hash, transaction_index, log_index metadata on each log.
pub fn appendBlockLogs(
    self: *LogIndex,
    allocator: std.mem.Allocator,
    block_number: u64,
    block_hash: [32]u8,
    receipts: []const primitives.Receipt.Receipt,
) !void

/// Execute a filter query. Returns owned slice of matching logs (caller frees).
/// Validates: blockHash mutually exclusive with fromBlock/toBlock.
/// Returns error.InvalidFilter for -32602 cases.
pub fn query(
    self: *const LogIndex,
    allocator: std.mem.Allocator,
    filter: LogFilter,
    head_block_number: u64,
) ![]primitives.EventLog.EventLog
```

**Filter validation** (returns `error.InvalidFilter`):
- `block_hash` set AND (`from_block` set OR `to_block` set) → invalid
- `from_block > to_block` → invalid (reversed range)
- `to_block > head_block_number` → invalid (future block)

**Topic matching** (`null` = wildcard, slice = OR at position):
```
match(log, filter):
  for each position i in filter.topics:
    if filter.topics[i] == null: continue  // wildcard
    if log.topics[i] not in filter.topics[i]: return false
  return true
```

---

### STEP 5 — Test: block query handlers (unit)

**File:** `src/rpc/block_queries_test.zig`

Tests to write, each uses a locally-built `Blockchain` + `ReceiptIndex` + `LogIndex`:

```
test "getBlockByNumber: returns null for missing block"
test "getBlockByNumber: returns genesis at tag 'earliest'"
test "getBlockByNumber: returns head block at tag 'latest'"
test "getBlockByNumber: returns block at hex number"
test "getBlockByNumber: fullTxs=false returns tx hashes"
test "getBlockByNumber: fullTxs=true returns tx objects"
test "getBlockByHash: returns block by 32-byte hash"
test "getBlockByHash: returns null for zero hash"
test "getBlockTransactionCountByNumber: returns 0x0 for empty block"
test "getBlockTransactionCountByNumber: returns correct count for block with txs"
test "getBlockTransactionCountByHash: returns null for missing block"
test "getBlockTransactionCountByHash: returns correct count"
```

---

### STEP 6 — Implement: block_queries.zig (block group)

**File:** `src/rpc/block_queries.zig`

```zig
/// Resolves a block-tag/number string to a block number.
/// Supports: "latest", "earliest", "safe", "finalized", "pending", "0x..."
pub fn resolveBlockTag(
    blockchain: *@import("blockchain").Blockchain,
    tag: []const u8,
) ?u64

/// eth_getBlockByNumber handler.
/// Returns JSON-serializable block object or null.
pub fn getBlockByNumber(
    allocator: std.mem.Allocator,
    blockchain: *@import("blockchain").Blockchain,
    tag: []const u8,
    full_txs: bool,
) !?BlockResponse

/// eth_getBlockByHash handler.
pub fn getBlockByHash(
    allocator: std.mem.Allocator,
    blockchain: *@import("blockchain").Blockchain,
    hash: [32]u8,
    full_txs: bool,
) !?BlockResponse

/// eth_getBlockTransactionCountByNumber handler.
pub fn getBlockTxCountByNumber(
    blockchain: *@import("blockchain").Blockchain,
    tag: []const u8,
) ?u64

/// eth_getBlockTransactionCountByHash handler.
pub fn getBlockTxCountByHash(
    blockchain: *@import("blockchain").Blockchain,
    hash: [32]u8,
) ?u64
```

**BlockResponse** struct (fields match execution-apis JSON output):
```zig
pub const BlockResponse = struct {
    hash: [32]u8,
    number: u64,
    parentHash: [32]u8,
    miner: [20]u8,
    stateRoot: [32]u8,
    transactionsRoot: [32]u8,
    receiptsRoot: [32]u8,
    logsBloom: [256]u8,
    difficulty: u256,
    gasLimit: u64,
    gasUsed: u64,
    timestamp: u64,
    extraData: []const u8,
    mixHash: [32]u8,
    nonce: [8]u8,
    baseFeePerGas: ?u256,
    withdrawalsRoot: ?[32]u8,
    blobGasUsed: ?u64,
    excessBlobGas: ?u64,
    parentBeaconBlockRoot: ?[32]u8,
    size: u64,
    totalDifficulty: ?u256,
    uncles: [][32]u8,
    transactions: TransactionList,  // hashes or full objects
};

pub const TransactionList = union(enum) {
    hashes: [][32]u8,
    full: []TxResponse,
};
```

---

### STEP 7 — Test: transaction query handlers (unit)

**File:** `src/rpc/block_queries_test.zig` (appended)

```
test "getTransactionByHash: returns null for missing"
test "getTransactionByHash: returns legacy tx object with all fields"
test "getTransactionByBlockHashAndIndex: returns null for missing block"
test "getTransactionByBlockHashAndIndex: returns null for out-of-range index"
test "getTransactionByBlockHashAndIndex: returns tx at valid index"
test "getTransactionByBlockNumberAndIndex: returns tx at valid index"
test "getTransactionByBlockNumberAndIndex: returns null for missing block"
```

---

### STEP 8 — Implement: transaction handlers in block_queries.zig

```zig
/// eth_getTransactionByHash handler.
pub fn getTransactionByHash(
    blockchain: *@import("blockchain").Blockchain,
    receipt_index: *ReceiptIndex,
    tx_hash: [32]u8,
) ?TxResponse

/// eth_getTransactionByBlockHashAndIndex handler.
pub fn getTransactionByBlockHashAndIndex(
    blockchain: *@import("blockchain").Blockchain,
    block_hash: [32]u8,
    index: usize,
) ?TxResponse

/// eth_getTransactionByBlockNumberAndIndex handler.
pub fn getTransactionByBlockNumberAndIndex(
    blockchain: *@import("blockchain").Blockchain,
    tag: []const u8,
    index: usize,
) ?TxResponse
```

**TxResponse** struct (per execution-apis, typed tx shapes):
```zig
pub const TxResponse = struct {
    blockHash: ?[32]u8,
    blockNumber: ?u64,
    blockTimestamp: ?u64,
    from: [20]u8,
    gas: u64,
    gasPrice: u256,
    maxFeePerGas: ?u256,
    maxPriorityFeePerGas: ?u256,
    hash: [32]u8,
    input: []const u8,
    nonce: u64,
    to: ?[20]u8,
    transactionIndex: ?u32,
    value: u256,
    type: u8,
    // EIP-2930
    accessList: ?[]AccessListEntry,
    chainId: ?u64,
    // EIP-1559 (no extra fields beyond max fees above)
    // EIP-4844
    maxFeePerBlobGas: ?u256,
    blobVersionedHashes: ?[][32]u8,
    // EIP-7702
    authorizationList: ?[]Authorization,
    // Signature
    v: u256,
    r: [32]u8,
    s: [32]u8,
    yParity: ?u8,
};
```

Note: `BlockBody.TransactionData` stores raw RLP bytes. The tx handler must decode these
to populate `TxResponse`. Decoding logic lives in voltaire's `primitives.Transaction` or
can be added there if missing. Do NOT duplicate decode logic in zevm.

---

### STEP 9 — Test: receipt query handlers (unit)

**File:** `src/rpc/block_queries_test.zig` (appended)

```
test "getTransactionReceipt: returns null for missing tx hash"
test "getTransactionReceipt: returns receipt with status=1 for success"
test "getTransactionReceipt: returns receipt with status=0 for revert"
test "getTransactionReceipt: includes logs with full metadata"
test "getTransactionReceipt: contractAddress non-null for create tx"
test "getTransactionReceipt: returns root field for pre-Byzantium receipt"
test "getBlockReceipts: returns null for missing block"
test "getBlockReceipts: returns empty array for block with no txs"
test "getBlockReceipts: returns all receipts in tx-index order"
```

---

### STEP 10 — Implement: receipt handlers in block_queries.zig

```zig
/// eth_getTransactionReceipt handler.
pub fn getTransactionReceipt(
    receipt_index: *const ReceiptIndex,
    tx_hash: [32]u8,
) ?ReceiptResponse

/// eth_getBlockReceipts handler.
pub fn getBlockReceipts(
    allocator: std.mem.Allocator,
    blockchain: *@import("blockchain").Blockchain,
    receipt_index: *const ReceiptIndex,
    tag: []const u8,
) !?[]ReceiptResponse
```

**ReceiptResponse** struct:
```zig
pub const ReceiptResponse = struct {
    transactionHash: [32]u8,
    transactionIndex: u32,
    blockHash: [32]u8,
    blockNumber: u64,
    from: [20]u8,
    to: ?[20]u8,
    cumulativeGasUsed: u256,
    gasUsed: u256,
    contractAddress: ?[20]u8,
    logs: []LogResponse,
    logsBloom: [256]u8,
    // Post-Byzantium: status field (0x0 or 0x1)
    status: ?u8,
    // Pre-Byzantium: root field
    root: ?[32]u8,
    effectiveGasPrice: u256,
    type: u8,
    // EIP-4844
    blobGasUsed: ?u256,
    blobGasPrice: ?u256,
};
```

---

### STEP 11 — Test: eth_getLogs handler (unit)

**File:** `src/rpc/block_queries_test.zig` (appended)

```
test "getLogs: returns empty slice for range with no matching logs"
test "getLogs: returns logs filtered by address"
test "getLogs: returns logs filtered by topic[0] exact match"
test "getLogs: topic null wildcard matches all"
test "getLogs: topic OR array matches any of the listed hashes"
test "getLogs: blockHash filter returns only that block"
test "getLogs: error on blockHash + fromBlock conflict"
test "getLogs: error on reversed block range"
test "getLogs: error on to_block > head_block"
test "getLogs: logs returned in canonical order (block, txIdx, logIdx)"
```

---

### STEP 12 — Implement: getLogs handler in block_queries.zig

```zig
pub const LogFilterError = error{
    InvalidFilter,
    OutOfMemory,
};

/// eth_getLogs handler.
/// Returns owned slice of logs (caller frees) or error.InvalidFilter (-32602).
pub fn getLogs(
    allocator: std.mem.Allocator,
    blockchain: *@import("blockchain").Blockchain,
    log_index: *const LogIndex,
    filter: LogFilter,
) LogFilterError![]LogResponse
```

**LogResponse** struct:
```zig
pub const LogResponse = struct {
    address: [20]u8,
    topics: [][32]u8,
    data: []const u8,
    blockNumber: u64,
    blockHash: [32]u8,
    blockTimestamp: ?u64,
    transactionHash: [32]u8,
    transactionIndex: u32,
    logIndex: u32,
    removed: bool,
};
```

---

### STEP 13 — Test: block_builder integration with receipt + log persistence

**File:** `src/block_builder_test.zig` (appended)

```
test "buildBlock result can be stored in ReceiptIndex"
test "block receipts stored in ReceiptIndex are retrievable by tx hash"
test "block logs stored in LogIndex are filterable by address"
```

These tests verify the end-to-end flow: `buildBlock` → `receipt_index.putBlockReceipts` →
`log_index.appendBlockLogs` → query works.

---

### STEP 14 — Wire receipt/log persistence into block commit flow

When a block is committed (caller code that uses `buildBlock` + `blockchain.putBlock`):

```zig
// After buildBlock and blockchain.putBlock:
try receipt_index.putBlockReceipts(allocator, block_hash, result.receipts);
try log_index.appendBlockLogs(allocator, block_number, block_hash, result.receipts);
```

This is not a new function — it's caller-side wiring. The plan file documents the contract
so future RPC server integration knows what to call.

---

### STEP 15 — Register new test files in root.zig

**File:** `src/root.zig`

Add to the test block:
```zig
_ = @import("receipt_index_test.zig");
_ = @import("log_index_test.zig");
_ = @import("rpc/block_queries_test.zig");
```

Add to the public exports:
```zig
pub const receipt_index = @import("receipt_index.zig");
pub const log_index = @import("log_index.zig");
pub const block_queries = @import("rpc/block_queries.zig");
```

---

### STEP 16 — Verify: zig build test passes

Run `zig build test`. All existing tests must remain green. All new tests must pass.

---

## Files to Create

| File | Purpose |
|------|---------|
| `src/receipt_index.zig` | ReceiptIndex: tx_hash→receipt, block_hash→receipts |
| `src/receipt_index_test.zig` | Unit tests for ReceiptIndex |
| `src/log_index.zig` | LogIndex: block-range scan + address/topic filter |
| `src/log_index_test.zig` | Unit tests for LogIndex |
| `src/rpc/block_queries.zig` | Handler functions for all 10 RPC methods |
| `src/rpc/block_queries_test.zig` | Unit tests for all RPC handler functions |

## Files to Modify

| File | Change |
|------|--------|
| `src/root.zig` | Export new modules + register new test files |
| `src/block_builder_test.zig` | Add integration tests for receipt/log persistence |

---

## Voltaire Gaps to Address First

Before implementing ZEVM handlers, verify these voltaire primitives are sufficient. Fix
upstream if anything is missing (do not duplicate in zevm):

### 1. Receipt `sender` field name
`Receipt.zig` uses `.sender` but `clone()` references `.from`. This is a bug — verify and
fix in voltaire (`../voltaire/packages/voltaire-zig/src/primitives/Receipt/Receipt.zig`).

### 2. Transaction decode from raw bytes
`BlockBody.TransactionData` stores `raw: []const u8`. ZEVM needs to decode raw bytes to
populate `TxResponse` fields (type, nonce, gasPrice, to, value, data, signature, etc.).
Check `primitives.Transaction` for existing decode functions. If missing, add them in
voltaire before implementing `getTransactionByHash`.

### 3. EventLog missing `block_hash` field
`EventLog` has `block_number`, `transaction_hash`, `transaction_index`, `log_index` but
**no `block_hash` field**. `eth_getLogs` responses require `blockHash`. Two options:
- Add `block_hash: ?[32]u8` to `EventLog` in voltaire **(preferred)**
- Store block_hash separately in `LogIndex` alongside logs

The preferred approach is to add the field to voltaire `EventLog.zig`. Do this first.

### 4. BlockHeader missing `blockTimestamp` on transactions
`eth_getTransactionByBlockHashAndIndex` vector returns `blockTimestamp`. Must be populated
from block header when building `TxResponse`. No voltaire change needed — read from block.

---

## Risks and Mitigations

### Risk 1: Raw tx decode complexity
`BlockBody.TransactionData.raw` is raw RLP for legacy txs or typed envelope for EIP-2718+.
Decoding all 5 tx types (legacy, 2930, 1559, 4844, 7702) is complex.

**Mitigation:** Start with legacy decode only (covers most test vectors). Add typed tx decode
incrementally. Mark incomplete types with `@panic("unimplemented: decode EIP-2930 tx")` so
tests fail loudly rather than silently return wrong data.

### Risk 2: LogIndex memory ownership
Logs contain `topics: []const Hash` and `data: []const u8` — borrowed slices. `LogIndex`
must clone these on insert to take ownership, or document that caller must keep source
receipts alive.

**Mitigation:** `appendBlockLogs` deep-clones each log using `EventLog.clone()` (already
exists in voltaire). `LogIndex.deinit` frees cloned log data.

### Risk 3: ReceiptIndex receipt ownership
Same issue — `Receipt` contains `logs: []const EventLog`.

**Mitigation:** `putBlockReceipts` calls `receipt.clone(allocator)` for each receipt to take
ownership. `deinit` calls `receipt.deinit(allocator)` for each stored receipt.

### Risk 4: blockHash exclusivity in getLogs
Spec requires error `-32602` when `blockHash` is combined with `fromBlock`/`toBlock`.

**Mitigation:** `LogFilter.validate()` function checks this early. Tests cover all three
error cases from execution-apis vectors.

### Risk 5: pre-Byzantium `root` vs `status` in receipts
`getTransactionReceipt` test vector `get-legacy-receipt.io` returns `root` field (not
`status`). Current `tx_processor.zig` always populates `status`, never `root`.

**Mitigation:** Dev node runs post-Byzantium only (status field). The `root` field in
`ReceiptResponse` will be `null` for all locally mined blocks. The receipt index can
store pre-Byzantium receipts fetched from fork if needed later.

### Risk 6: Missing block tags `safe` and `finalized`
`eth_getBlockByNumber("safe", false)` and `"finalized"` are in test vectors.

**Mitigation:** In a dev node, `safe` and `finalized` map to `latest`. `resolveBlockTag`
handles this explicitly.

---

## Acceptance Criteria Verification

| # | Criterion | Verified by |
|---|-----------|-------------|
| 1 | `getBlockByNumber` returns block with header fields | `block_queries_test.zig` |
| 2 | `getBlockByNumber` supports `fullTxs=true/false` | `block_queries_test.zig` |
| 3 | `getBlockByNumber` supports `latest`, `earliest`, `pending`, `safe`, hex | `block_queries_test.zig` |
| 4 | `getBlockByHash` returns block by 32-byte hash | `block_queries_test.zig` |
| 5 | `getTransactionByHash` returns tx from any mined block | `block_queries_test.zig` |
| 6 | `getTransactionReceipt` returns receipt with logs, status, gasUsed, contractAddress | `block_queries_test.zig` |
| 7 | `getBlockReceipts` returns all receipts for a block | `block_queries_test.zig` |
| 8 | `getLogs` filters by address, topics, fromBlock, toBlock | `log_index_test.zig` + `block_queries_test.zig` |
| 9 | `getLogs` supports multiple addresses and topic arrays | `log_index_test.zig` |
| 10 | `getBlockTransactionCountByNumber/Hash` return correct counts | `block_queries_test.zig` |
| 11 | Receipt storage persists receipts alongside mined blocks | `block_builder_test.zig` (step 13) |
| 12 | `execution-apis/tests/eth_getBlockByNumber/` passes | conformance harness |
| 13 | `execution-apis/tests/eth_getTransactionByHash/` passes | conformance harness |
| 14 | `execution-apis/tests/eth_getTransactionReceipt/` passes | conformance harness |
| 15 | `execution-apis/tests/eth_getLogs/` passes | conformance harness |
| 16 | `zig build test` passes | CI |

---

## Conformance Notes

The execution-apis `.io` test vector format (`>> request`, `<< response`) requires an HTTP
JSON-RPC server to run against. A future ticket will wire these handlers into the HTTP
server and run the vector files. For this ticket, the unit tests in `block_queries_test.zig`
mirror the exact request/response shapes from the vectors and validate handler correctness
at the function level.

Key test vector behaviors to cover explicitly:
- `get-block-notfound.io` → handler returns `null`
- `get-block-london-fork.io` → baseFeePerGas present
- `get-genesis.io` (block receipts) → returns `[]` (empty, not null)
- `get-block-receipts-not-found.io` → returns `null`
- `filter-error-invalid-blockHash-and-range.io` → error code `-32602`
- `filter-error-reversed-block-range.io` → error code `-32602`
- `get-legacy-receipt.io` → `root` field present (pre-Byzantium mock data)
